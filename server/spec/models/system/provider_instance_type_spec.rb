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
end
