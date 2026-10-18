# A narrowly scoped, idempotent invitation; requires the human-approved recipient.
require "spaceship"
require "json"
require "net/http"
require "uri"
require "digest"

email = ENV.fetch("INVITATION_EMAIL").strip.downcase
raise "Invalid invitation email" unless email.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
puts "::add-mask::#{email}"
app_id = "6789744416"
bundle = "com.D3GG62L9X8.LoopFollow"
token = Spaceship::ConnectAPI::Token.create(key_id: ENV.fetch("FASTLANE_KEY_ID"), issuer_id: ENV.fetch("FASTLANE_ISSUER_ID"), key: ENV.fetch("FASTLANE_KEY"), duration: 300)
request = lambda do |path, body = nil|
  uri = URI("https://api.appstoreconnect.apple.com" + path)
  req = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer " + token.text
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) { |http| http.request(req) }
  raise "Invitation request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end
result = {recipientSHA256: Digest::SHA256.hexdigest(email), appID: app_id, otherAppsGranted: nil, provisioningAllowed: nil}
begin
  app = request.call("/v1/apps/#{app_id}").fetch("data")
  raise "Unexpected app identity" unless app.fetch("attributes")["bundleId"] == bundle
  users = request.call("/v1/users?limit=200").fetch("data")
  existing_user = users.find { |u| u.fetch("attributes")["username"].to_s.downcase == email }
  if existing_user
    result[:status] = "existing_account_requires_group_membership"
    result[:userID] = existing_user.fetch("id")
  else
    pending = request.call("/v1/userInvitations?limit=200").fetch("data")
    invitation = pending.find { |i| i.fetch("attributes")["email"].to_s.downcase == email }
    unless invitation
      name = email.split("@").first.split(/[._-]+/).map(&:capitalize)
      body = {data: {type: "userInvitations", attributes: {email: email, firstName: name.first, lastName: name.drop(1).join(" "), roles: ["MARKETING"], allAppsVisible: false, provisioningAllowed: false}, relationships: {visibleApps: {data: [{type: "apps", id: app_id}]}}}}
      invitation = request.call("/v1/userInvitations", body).fetch("data")
      result[:newInvitationSent] = true
    end
    query = URI.encode_www_form({"include" => "visibleApps", "fields[userInvitations]" => "email,roles,allAppsVisible,provisioningAllowed,visibleApps"})
    # List/create responses can omit fields. Verify the full invitation resource.
    verified = request.call("/v1/userInvitations/#{invitation.fetch('id')}?#{query}").fetch("data")
    attrs = verified.fetch("attributes")
    visible = verified.fetch("relationships").fetch("visibleApps").fetch("data").map { |a| a.fetch("id") }
    result[:reportedScope] = {allAppsVisible: attrs["allAppsVisible"], provisioningAllowed: attrs["provisioningAllowed"], visibleAppIDs: visible, roles: attrs["roles"]}
    raise "Unexpected invitation role" unless attrs["roles"] == ["MARKETING"]
    # Apple omits this optional flag on pending invitation reads. The explicit
    # visibleApps relationship must still contain exactly LoopFollow below.
    raise "Unexpected all-app access" unless [false, nil].include?(attrs["allAppsVisible"])
    raise "Unexpected provisioning access" unless attrs["provisioningAllowed"] == false
    raise "Unexpected visible apps" unless visible == [app_id]
    result[:otherAppsGranted] = false
    result[:provisioningAllowed] = false
    result[:invitationID] = invitation.fetch("id")
    result[:status] = "pending_recipient_acceptance"
    result[:roles] = attrs["roles"]
  end
  File.write(ARGV.fetch(0), JSON.pretty_generate(result) + "\n")
  puts JSON.generate(result)
rescue => error
  result[:status] = result[:newInvitationSent] ? "invitation_sent_verification_failed" : "verification_failed"
  result[:error] = error.message
  File.write(ARGV.fetch(0), JSON.pretty_generate(result) + "\n")
  warn JSON.generate(result)
  raise
end
