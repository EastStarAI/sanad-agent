# frozen_string_literal: true

# Pure decisions the App Store lane makes about a version or a build that already
# exists in App Store Connect.
#
# Nothing here talks to fastlane, Spaceship, or the network, so
# `test_store_state.rb` proves the behaviour offline and the same rules cannot
# drift between the lane and its test.
module SanadStoreState
  # App Store Connect leaves a version actionable for `deliver` only while it is
  # one of PREPARE_FOR_SUBMISSION, DEVELOPER_REJECTED, REJECTED,
  # METADATA_REJECTED, INVALID_BINARY, or READY_FOR_REVIEW. Everything below has
  # already been submitted, is in review, is approved, or is live, so a second
  # submission attempt must not run.
  SUBMITTED_OR_LATER = %w[
    WAITING_FOR_REVIEW
    IN_REVIEW
    PENDING_DEVELOPER_RELEASE
    PENDING_APPLE_RELEASE
    PREORDER_READY_FOR_SALE
    PROCESSING_FOR_APP_STORE
    READY_FOR_SALE
    REPLACED_WITH_NEW_VERSION
  ].freeze

  module_function

  # A version that already left the editable state is a completed submission,
  # not an error: the store workflow is re-runnable for the same tag.
  def already_submitted?(state)
    SUBMITTED_OR_LATER.include?(state.to_s.upcase)
  end

  # TestFlight build numbers are per marketing version and are never reused, so a
  # latest build at or above the wanted one proves the upload already happened.
  # Retrying that upload would be rejected by App Store Connect as a duplicate.
  def build_present?(latest:, wanted:)
    latest = Integer(latest.to_s, exception: false)
    wanted = Integer(wanted.to_s, exception: false)
    return false if latest.nil? || wanted.nil?

    latest >= wanted
  end
end
