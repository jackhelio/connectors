require "spec_helper"
require "open3"

RSpec.describe "Gem distribution" do
  it "builds, installs and boots the packaged gem with its documentation" do
    output, status = Open3.capture2e(Gem.ruby, File.expand_path("../script/verify_package.rb", __dir__))
    expect(status.success?).to be(true), output
  end
end
