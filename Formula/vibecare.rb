class Vibecare < Formula
  desc "Personal routine and schedule management system with macOS client"
  homepage "https://github.com/vibecare-io/vibecare"
  url "https://github.com/vibecare-io/vibecare/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"
  head "https://github.com/vibecare-io/vibecare.git", branch: "main"

  depends_on "go" => :build
  depends_on "swift" => :build
  depends_on :macos

  def install
    # Build backend
    cd "backend" do
      system "go", "build", *std_go_args(ldflags: "-s -w -X main.version=#{version}",
                                         output: bin/"vibecare-server"),
             "cmd/server/main.go"
    end

    # Build macOS client
    cd "clients/macos-swift/VibeCare" do
      system "swift", "build", "-c", "release"
      bin.install ".build/release/VibeCare" => "vibecare-client"
    end

    # Install LaunchAgent plist
    (prefix/"LaunchAgents").install "scripts/io.vibecare.server.plist"

    # Create data directory
    (var/"vibecare").mkpath
  end

  def post_install
    # Create log directory
    (var/"log/vibecare").mkpath

    # Copy LaunchAgent to user's LaunchAgents directory
    launchagent_src = prefix/"LaunchAgents/io.vibecare.server.plist"
    launchagent_dst = "#{Dir.home}/Library/LaunchAgents/io.vibecare.server.plist"

    unless File.exist?(launchagent_dst)
      # Read the plist and replace paths
      plist_content = File.read(launchagent_src)
      plist_content.gsub!("/usr/local/bin/vibecare-server", "#{bin}/vibecare-server")
      plist_content.gsub!("~/.vibecare", "#{var}/vibecare")
      plist_content.gsub!("~/Library/Logs/VibeCare", "#{var}/log/vibecare")

      File.write(launchagent_dst, plist_content)
      FileUtils.chmod 0644, launchagent_dst
    end
  end

  def caveats
    <<~EOS
      VibeCare has been installed!

      To start the backend server automatically:
        brew services start vibecare

      Or load the LaunchAgent manually:
        launchctl load ~/Library/LaunchAgents/io.vibecare.server.plist

      To run the macOS client:
        vibecare-client

      The backend will be available at:
        - Web Dashboard: http://localhost:8080/status
        - gRPC: localhost:50051

      Data directory: #{var}/vibecare
      Logs directory: #{var}/log/vibecare
    EOS
  end

  service do
    run opt_bin/"vibecare-server"
    environment_variables PATH: std_service_path_env
    keep_alive true
    log_path var/"log/vibecare/server.log"
    error_log_path var/"log/vibecare/server-error.log"
    working_dir var/"vibecare"
  end

  test do
    # Test backend version
    assert_match version.to_s, shell_output("#{bin}/vibecare-server --version 2>&1", 1)

    # Test client exists
    assert_predicate bin/"vibecare-client", :exist?
  end
end
