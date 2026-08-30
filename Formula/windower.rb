class Windower < Formula
  desc "Fast macOS CLI to list and focus windows"
  homepage "https://github.com/750/windower"
  url "https://github.com/750/windower/releases/download/v0.2.0/windower-0.2.0.tar.gz",
      using: :homebrew_curl
  version "0.2.0"
  sha256 "762bababda69a3f4b55cf901010d6f5385dd7aeee3244d60d8a7960bf20d010e"
  license "MIT"

  # Prebuilt binary — no compiler/Xcode needed at install time.
  def install
    bin.install "windower"
  end

  test do
    assert_match "windower", shell_output("#{bin}/windower --help")
  end
end
