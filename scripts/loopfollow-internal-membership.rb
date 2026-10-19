# Complete the explicitly authorized LoopFollow invitation after acceptance.
# Never change account roles or substitute an external tester group.
require "uri"

def ensure_loopfollow_internal_membership(request:, email:, user_id:, app_id:, group_id:)
  query = URI.encode_www_form("include" => "visibleApps", "fields[users]" => "username,roles,allAppsVisible,provisioningAllowed,visibleApps")
  user = request.call("/v1/users/#{user_id}?#{query}").fetch("data")
  attrs = user.fetch("attributes")
  visible = user.fetch("relationships").fetch("visibleApps").fetch("data").map { |app| app.fetch("id") }
  raise "Unexpected accepted account" unless attrs.fetch("username").downcase == email
  raise "Unexpected accepted account role" unless attrs["roles"] == ["MARKETING"]
  # A human may have granted this existing account other apps after accepting.
  # Do not edit/revoke that access. Only enroll in the already-authorized LF
  # group, and require that the account already has access to LF.
  raise "Unexpected accepted account app access" unless [true, false, nil].include?(attrs["allAppsVisible"]) && (attrs["allAppsVisible"] == true || visible.include?(app_id))
  raise "Unexpected accepted account provisioning access" unless attrs["provisioningAllowed"] == false

  group = request.call("/v1/betaGroups/#{group_id}?include=app").fetch("data")
  raise "Expected an internal tester group" unless group.fetch("attributes")["isInternalGroup"] == true
  raise "Unexpected tester group app" unless group.fetch("relationships").fetch("app").fetch("data").fetch("id") == app_id

  query = URI.encode_www_form("filter[email]" => email, "limit" => 200)
  testers = request.call("/v1/betaTesters?#{query}").fetch("data").select { |tester| tester.fetch("attributes")["email"].to_s.downcase == email }
  raise "Ambiguous beta tester identity" if testers.length > 1
  tester = testers.first
  unless tester
    tester = request.call("/v1/betaTesters", {data: {type: "betaTesters", attributes: {email: email}, relationships: {betaGroups: {data: [{type: "betaGroups", id: group_id}]}}}}).fetch("data")
    raise "Unexpected created tester" unless tester.fetch("attributes")["email"].to_s.downcase == email
  end

  members_path = "/v1/betaGroups/#{group_id}/relationships/betaTesters?limit=200"
  members = request.call(members_path).fetch("data").map { |member| member.fetch("id") }
  unless members.include?(tester.fetch("id"))
    request.call("/v1/betaGroups/#{group_id}/relationships/betaTesters", {data: [{type: "betaTesters", id: tester.fetch("id")}]})
    members = request.call(members_path).fetch("data").map { |member| member.fetch("id") }
  end
  raise "Tester membership not confirmed" unless members.include?(tester.fetch("id"))

  {status: "internal_tester_membership_verified", appID: app_id, groupID: group_id,
   otherAppsGranted: false, provisioningAllowed: false, roles: attrs["roles"], accountScopeUnchanged: true,
   existingAccountScope: {allAppsVisible: attrs["allAppsVisible"], visibleAppIDs: visible}}
end
