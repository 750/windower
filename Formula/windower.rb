class Windower < Formula
  desc "Fast macOS CLI to list and focus windows"
  homepage "https://github.com/750/windower"
  url "https://github.com/750/windower/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "deefd8e2651f084e42715ff4f624794737e320543ac5bce2cb29b251ea592622"
  license "MIT"

  # Swift is provided by Xcode Command Line Tools on macOS (no `swift` brew dep).
  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/windower"
  end

  test do
    assert_match "windower", shell_output("#{bin}/windower --help")
  end
end
