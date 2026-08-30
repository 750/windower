class Windower < Formula
  desc "Fast macOS CLI to list and focus windows"
  homepage "https://github.com/750/windower"
  url "https://github.com/750/windower/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  # Swift is provided by Xcode Command Line Tools on macOS.
  depends_on "swift" => :build

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/windower"
  end

  test do
    assert_match "windower", shell_output("#{bin}/windower --help")
  end
end
