require "minitest/autorun"
require_relative "loopfollow-internal-membership"

class LoopFollowInternalMembershipTest < Minitest::Test
  def setup
    @email = "authorized@example.invalid"
    @user = {"attributes" => {"username" => @email, "roles" => ["MARKETING"], "allAppsVisible" => false, "provisioningAllowed" => false},
             "relationships" => {"visibleApps" => {"data" => [{"id" => "lf"}]}}}
    @group = {"attributes" => {"isInternalGroup" => true}, "relationships" => {"app" => {"data" => {"id" => "lf"}}}}
    @tester = {"id" => "tester", "attributes" => {"email" => @email}}
    @testers = [@tester]
    @members = []
    @writes = []
    @persist = true
  end

  def complete
    request = lambda do |path, body = nil|
      if body
        @writes << [path, body]
        if path == "/v1/betaTesters"
          @testers = [@tester]
          @members = [{"id" => "tester"}] if @persist
          {"data" => @tester}
        else
          @members = [{"id" => "tester"}] if @persist
          {}
        end
      elsif path.start_with?("/v1/users/")
        {"data" => @user}
      elsif path.include?("/relationships/betaTesters")
        {"data" => @members}
      elsif path.start_with?("/v1/betaGroups/")
        {"data" => @group}
      else
        {"data" => @testers}
      end
    end
    ensure_loopfollow_internal_membership(request: request, email: @email, user_id: "user", app_id: "lf", group_id: "group")
  end

  def test_existing_tester_is_added_once_and_read_back
    assert_equal "internal_tester_membership_verified", complete[:status]
    assert_equal [["/v1/betaGroups/group/relationships/betaTesters", {data: [{type: "betaTesters", id: "tester"}]}]], @writes
    complete
    assert_equal 1, @writes.length
  end

  def test_missing_tester_is_created_only_in_approved_internal_group
    @testers = []
    assert_equal false, complete[:otherAppsGranted]
    assert_equal 1, @writes.length
    assert_equal "/v1/betaTesters", @writes.first.first
    assert_equal [{type: "betaGroups", id: "group"}], @writes.first.last[:data][:relationships][:betaGroups][:data]
  end

  def test_wrong_account_role_or_scope_blocks_all_writes
    @user["attributes"]["roles"] = ["ADMIN"]
    assert_raises(RuntimeError) { complete }
    assert_empty @writes
    @user["attributes"]["roles"] = ["MARKETING"]
    @user["relationships"]["visibleApps"]["data"] << {"id" => "other"}
    assert_raises(RuntimeError) { complete }
    assert_empty @writes
  end

  def test_external_or_wrong_app_group_blocks_all_writes
    @group["attributes"]["isInternalGroup"] = false
    assert_raises(RuntimeError) { complete }
    assert_empty @writes
    @group["attributes"]["isInternalGroup"] = true
    @group["relationships"]["app"]["data"]["id"] = "other"
    assert_raises(RuntimeError) { complete }
    assert_empty @writes
  end

  def test_unconfirmed_membership_is_not_reported_as_success
    @persist = false
    assert_raises(RuntimeError) { complete }
  end
end
