# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ProviderInstanceType, type: :model do
  let(:account) { create(:account) }

  def itype(**attrs)
    create(:system_provider_instance_type, account: account, **attrs)
  end

  describe "GPU capability (audit P6)" do
    it "#gpu? is true only when gpu_count is positive" do
      expect(itype(gpu_count: 0).gpu?).to be(false)
      expect(itype(gpu_count: 2).gpu?).to be(true)
    end

    it "#gpu_memory_gb converts per-GPU VRAM from MB (nil without a GPU)" do
      expect(itype(gpu_count: 1, gpu_memory_mb: 81_920).gpu_memory_gb).to eq(80.0)
      expect(itype(gpu_count: 0).gpu_memory_gb).to be_nil
    end

    it "#gpu_summary renders 'count x type VRAM' (nil without a GPU)" do
      t = itype(gpu_count: 8, gpu_type: "H100", gpu_memory_mb: 81_920)
      expect(t.gpu_summary).to eq("8x H100 80 GB")
      expect(itype(gpu_count: 0).gpu_summary).to be_nil
    end

    it "#display_name appends the GPU summary when present" do
      t = itype(name: "p5.48xlarge", vcpus: 192, memory_mb: 2_097_152,
                gpu_count: 8, gpu_type: "H100", gpu_memory_mb: 81_920)
      expect(t.display_name).to include("8x H100 80 GB")
    end

    describe "scopes" do
      let!(:cpu)  { itype(gpu_count: 0) }
      let!(:l40)  { itype(gpu_count: 1, gpu_type: "L40S", gpu_memory_mb: 49_152) }
      let!(:h100) { itype(gpu_count: 8, gpu_type: "H100", gpu_memory_mb: 81_920) }

      it ".with_gpu returns only GPU SKUs" do
        expect(described_class.where(account_id: account.id).with_gpu).to contain_exactly(l40, h100)
      end

      it ".by_gpu filters by accelerator type (case-insensitive)" do
        expect(described_class.where(account_id: account.id).by_gpu("h100")).to contain_exactly(h100)
      end

      it ".by_gpu honors a minimum GPU count" do
        expect(described_class.where(account_id: account.id).by_gpu(nil, min_count: 2)).to contain_exactly(h100)
      end
    end
  end
  # APO-2c — the pricing resolution core's money path reads. #price_in_region
  # is consumed by Ai::Provisioning::CostEstimatorService for the operator's
  # plan-time quote and #pricing_row_for by ProjectMetricsCollector for the
  # month-to-date accrual; both were unpinned by any spec, so a later edit
  # could change what an operator is quoted without going red.
  describe "pricing resolution" do
    let(:region) { create(:system_provider_region, account: account) }
    let(:type)   { itype(hourly_price: 0.05, currency: "USD") }

    def region_row(**attrs)
      System::RegionInstanceType.create!(
        provider_region: region, provider_instance_type: type, available: true, **attrs
      )
    end

    it "falls back to the base row when the SKU has no row in that region" do
      expect(type.pricing_row_for(region)).to eq(type)
      expect(type.price_in_region(region)).to eq(0.05)
    end

    it "falls back to the base row when region is nil" do
      expect(type.pricing_row_for(nil)).to eq(type)
      expect(type.price_in_region(nil)).to eq(0.05)
    end

    # A region row without a rate is an AVAILABILITY row, not a price.
    it "falls back to the base row when the region row carries no rate" do
      region_row(hourly_price: nil)
      expect(type.pricing_row_for(region)).to eq(type)
      expect(type.price_in_region(region)).to eq(0.05)
    end

    it "prices from the region row when it carries a rate" do
      row = region_row(hourly_price: 0.10)
      expect(type.pricing_row_for(region)).to eq(row)
      expect(type.price_in_region(region)).to eq(0.10)
    end

    # 0.0 is truthy in Ruby, so an explicit zero override is a DECLARED rate
    # and must win over the base rate rather than falling through it. (Whether
    # a zero is a real price is the CALLER's judgement — the accrual sampler
    # treats it as an unpopulated row on a billed provider.)
    it "honours an explicit zero override rather than falling through it" do
      row = region_row(hourly_price: 0.0)
      expect(type.pricing_row_for(region)).to eq(row)
      expect(type.price_in_region(region)).to eq(0.0)
    end

    # The rate and the currency it is quoted in must come off ONE row.
    it "answers #effective_currency on whichever row priced the SKU" do
      expect(type.pricing_row_for(region).effective_currency).to eq("USD")
      expect(itype(hourly_price: 0.05, currency: nil).effective_currency).to eq("USD")

      eur = itype(hourly_price: 0.05, currency: "EUR")
      expect(eur.effective_currency).to eq("EUR")

      row = region_row(hourly_price: 0.10, currency: "EUR")
      expect(type.pricing_row_for(region).effective_currency).to eq("EUR")
      expect(row.effective_currency).to eq("EUR")
    end
  end
end
