#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline tests for client/ios/fastlane/store_state.rb.
#
# No framework and no network: the App Store lane's re-run decisions are pure
# functions, and CI runs this file directly.
#
#   ruby client/ios/fastlane/test_store_state.rb

require_relative "store_state"

FAILURES = []

def check(name)
  return if yield

  FAILURES << name
  warn("FAIL: #{name}")
end

# A version that already left the editable state must stop a second submission.
%w[
  WAITING_FOR_REVIEW
  IN_REVIEW
  PENDING_DEVELOPER_RELEASE
  PENDING_APPLE_RELEASE
  PREORDER_READY_FOR_SALE
  PROCESSING_FOR_APP_STORE
  READY_FOR_SALE
  REPLACED_WITH_NEW_VERSION
].each do |state|
  check("#{state} is already submitted") { SanadStoreState.already_submitted?(state) }
end

# Every state `deliver` can still act on must be allowed through.
%w[
  PREPARE_FOR_SUBMISSION
  DEVELOPER_REJECTED
  REJECTED
  METADATA_REJECTED
  INVALID_BINARY
  READY_FOR_REVIEW
].each do |state|
  check("#{state} is still actionable") { !SanadStoreState.already_submitted?(state) }
end

check("an unknown state is not treated as submitted") do
  !SanadStoreState.already_submitted?("SOMETHING_NEW")
end
check("a missing state is not treated as submitted") do
  !SanadStoreState.already_submitted?(nil)
end
check("a lower-case state is recognised") do
  SanadStoreState.already_submitted?("waiting_for_review")
end

# Build presence decides whether the upload may run again.
check("the same build is present") { SanadStoreState.build_present?(latest: 27, wanted: 27) }
check("a later build proves the upload happened") { SanadStoreState.build_present?(latest: 28, wanted: 27) }
check("a lower build is missing") { !SanadStoreState.build_present?(latest: 26, wanted: 27) }
check("no build at all is missing") { !SanadStoreState.build_present?(latest: 0, wanted: 27) }
check("string build numbers are compared numerically") do
  SanadStoreState.build_present?(latest: "27", wanted: "27")
end
check("a larger number is not compared lexically") do
  SanadStoreState.build_present?(latest: "100", wanted: "99")
end
check("an unusable latest value is missing") { !SanadStoreState.build_present?(latest: "", wanted: 27) }
check("an unusable wanted value is missing") { !SanadStoreState.build_present?(latest: 27, wanted: nil) }

if FAILURES.empty?
  puts "App Store re-run decisions passed."
  exit 0
end

warn("#{FAILURES.length} failure(s).")
exit 1
