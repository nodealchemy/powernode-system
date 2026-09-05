# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/schema_defect_helpers"

RSpec.describe System::DeployDefect do
  describe ".schema?" do
    it "recognises a StatementInvalid caused by a missing table" do
      expect(described_class.schema?(schema_defect_error)).to be(true)
    end

    it "recognises a missing column, wrapped the same way" do
      error = begin
        raise PG::UndefinedColumn, 'ERROR:  column "tick_count" does not exist'
      rescue PG::UndefinedColumn
        begin
          raise ActiveRecord::StatementInvalid, "PG::UndefinedColumn: column does not exist"
        rescue ActiveRecord::StatementInvalid => wrapped
          wrapped
        end
      end

      expect(described_class.schema?(error)).to be(true)
    end

    it "recognises an attribute the model was written against and the row lacks" do
      expect(described_class.schema?(ActiveModel::MissingAttributeError.new("can't write unknown attribute `x`"))).to be(true)
      expect(described_class.schema?(ActiveModel::UnknownAttributeError.new(Object.new, "x"))).to be(true)
    end

    # The discriminator is the CAUSE, not the wrapper: these share the
    # StatementInvalid class with a schema defect and must stay swallowed.
    it "does not mistake a deadlock, a lock wait or a cancelled query for a deploy defect" do
      expect(described_class.schema?(transient_statement_error)).to be(false)
      expect(described_class.schema?(ActiveRecord::LockWaitTimeout.new("lock wait"))).to be(false)
      expect(described_class.schema?(ActiveRecord::QueryCanceled.new("canceled"))).to be(false)
    end

    it "does not mistake an ordinary runtime error for one" do
      expect(described_class.schema?(RuntimeError.new("boom"))).to be(false)
      expect(described_class.schema?(ActiveRecord::RecordInvalid.new)).to be(false)
    end

    it "walks the whole cause chain, not just the top error" do
      outer = begin
        begin
          raise schema_defect_error
        rescue ActiveRecord::StatementInvalid
          raise RuntimeError, "wrapped once more by a caller"
        end
      rescue RuntimeError => e
        e
      end

      expect(outer.cause).to be_a(ActiveRecord::StatementInvalid)
      expect(described_class.schema?(outer)).to be(true)
    end

    it "answers false for a non-exception" do
      expect(described_class.schema?(nil)).to be(false)
    end
  end
end
