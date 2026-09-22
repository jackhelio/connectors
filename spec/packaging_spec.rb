require "spec_helper"
require "open3"

RSpec.describe "Gem distribution" do
  it "builds, installs and boots the packaged gem without host database configuration" do
    output, status = Open3.capture2e({ "DATABASE_URL" => nil }, Gem.ruby, File.expand_path("../script/verify_package.rb", __dir__))
    expect(status.success?).to be(true), output
  end
end
