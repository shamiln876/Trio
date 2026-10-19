# Read-only App Store Connect status. Never emit keys, tokens or tester identities.
require "spaceship"
require "json"
require "net/http"
require "uri"

bundle = ARGV.fetch(0)
raise "Unsupported app" unless ["com.D3GG62L9X8.LoopFollow", "org.nightscout.D3GG62L9X8.trio"].include?(bundle)
token = Spaceship::ConnectAPI::Token.create(key_id: ENV.fetch("FASTLANE_KEY_ID"), issuer_id: ENV.fetch("FASTLANE_ISSUER_ID"), key: ENV.fetch("FASTLANE_KEY"), duration: 300)
get = lambda do |path, query = {}|
  uri = URI("https://api.appstoreconnect.apple.com" + path)
  uri.query = URI.encode_www_form(query) unless query.empty?
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer " + token.text
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) { |http| http.request(request) }
  raise "App Store Connect status request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end
apps = get.call("/v1/apps", {"filter[bundleId]" => bundle}).fetch("data")
raise "Expected existing app" unless apps.length == 1
app = apps.first
# The relationship endpoint does not accept sort. Read the existing builds,
# then select the newest locally; never mistake an old first page for latest.
builds = []
path = "/v1/apps/#{app.fetch('id')}/builds"
query = {"limit" => 200}
loop do
  page = get.call(path, query)
  builds.concat(page.fetch("data"))
  following = page.fetch("links", {})["next"]
  break unless following
  next_uri = URI(following)
  raise "Unexpected pagination host" unless next_uri.host == "api.appstoreconnect.apple.com"
  path = next_uri.path
  query = URI.decode_www_form(next_uri.query || "").to_h
end
builds = builds.sort_by { |b| b.fetch("attributes")["uploadedDate"].to_s }.reverse.first(5)
groups = get.call("/v1/apps/#{app.fetch('id')}/betaGroups", {"limit" => 200}).fetch("data")
result = {bundleID: bundle, appID: app.fetch("id"), builds: [], groups: groups.map { |g| {id: g.fetch("id"), internal: g.fetch("attributes")["isInternalGroup"], automaticDistribution: g.fetch("attributes")["hasAccessToAllBuilds"]} }}
builds.each do |build|
  attrs = build.fetch("attributes")
  detail = get.call("/v1/builds/#{build.fetch('id')}/buildBetaDetail")["data"]
  result[:builds] << {id: build.fetch("id"), build: attrs["version"], processingState: attrs["processingState"], expired: attrs["expired"], beta: detail && detail["attributes"].slice("internalBuildState", "externalBuildState")}
end
File.write(ARGV.fetch(1), JSON.pretty_generate(result) + "\n")
puts JSON.generate(result)
