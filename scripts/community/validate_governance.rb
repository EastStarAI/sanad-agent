#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'set'

ROOT = File.expand_path('../..', __dir__)
REQUIRED_GROUPS = {
  'type' => %w[type/bug type/feature type/docs type/security type/performance type/refactor type/test type/maintenance],
  'component' => %w[comp/agent comp/client comp/protocol comp/providers comp/tools comp/install-update comp/ci-release comp/docs],
  'platform' => %w[platform/windows platform/macos platform/linux platform/android platform/ios platform/web],
  'priority' => %w[P0-critical P1-high P2-medium P3-low],
  'triage' => %w[needs-triage needs-repro needs-decision blocked ready-for-contributor good-first-issue help-wanted],
  'closure' => %w[duplicate invalid wontfix not-planned],
  'protected-review' => %w[maintainer-reviewed security-reviewed release-reviewed],
  'size' => %w[size/small size/medium size/large]
}.freeze


def fail_validation(message)
  warn "Governance validation failed: #{message}"
  exit 1
end


def load_yaml(path)
  YAML.safe_load(File.read(path), aliases: false) || {}
rescue Psych::SyntaxError => e
  fail_validation("invalid YAML in #{path.sub(ROOT + '/', '')}: #{e.message.lines.first.strip}")
end

labels_path = if ARGV.first == '--labels-only'
                ARGV[1] || File.join(ROOT, '.github/labels.yml')
              else
                File.join(ROOT, '.github/labels.yml')
              end
labels_data = load_yaml(labels_path)
labels = labels_data['labels']
fail_validation('labels manifest must contain a non-empty labels list') unless labels.is_a?(Array) && !labels.empty?

names = Set.new
groups = Hash.new { |hash, key| hash[key] = [] }
labels.each do |label|
  fail_validation('every label must be a mapping') unless label.is_a?(Hash)
  name = label['name'].to_s
  color = label['color'].to_s
  description = label['description'].to_s.strip
  group = label['group'].to_s
  fail_validation("duplicate label #{name}") unless names.add?(name)
  fail_validation("invalid color for #{name}") unless color.match?(/\A[0-9a-fA-F]{6}\z/)
  fail_validation("empty description for #{name}") if description.empty?
  fail_validation("tab or newline in description for #{name}") if description.match?(/[\t\r\n]/)
  fail_validation("unknown group #{group} for #{name}") unless REQUIRED_GROUPS.key?(group)
  groups[group] << name
end
REQUIRED_GROUPS.each do |group, expected|
  actual = groups[group]
  missing = expected - actual
  extra = actual - expected
  fail_validation("group #{group} missing=#{missing.inspect} extra=#{extra.inspect}") unless missing.empty? && extra.empty?
end

if ARGV.first == '--labels-only'
  puts "Labels valid: #{labels.length} unique entries across #{groups.length} groups."
  exit 0
end

yaml_paths = Dir.glob(File.join(ROOT, '.github/**/*.{yml,yaml}')).sort
yaml_paths.each { |path| load_yaml(path) }

issue_forms = Dir.glob(File.join(ROOT, '.github/ISSUE_TEMPLATE/*.yml'))
issue_forms.each do |path|
  data = load_yaml(path)
  next if File.basename(path) == 'config.yml'
  Array(data['labels']).each do |label|
    fail_validation("#{path.sub(ROOT + '/', '')} uses unknown label #{label}") unless names.include?(label)
  end
  serialized = File.read(path).downcase
  fail_validation("#{path.sub(ROOT + '/', '')} does not warn about redaction or secrets") unless serialized.include?('secret') || serialized.include?('redact')
end

config = load_yaml(File.join(ROOT, '.github/ISSUE_TEMPLATE/config.yml'))
fail_validation('blank issues must be disabled') unless config['blank_issues_enabled'] == false

required_files = %w[
  SECURITY.md CONTRIBUTING.md
  .github/CODE_OF_CONDUCT.md .github/GOVERNANCE.md .github/SUPPORT.md
  .github/CODEOWNERS .github/PULL_REQUEST_TEMPLATE.md .github/branch-protection.yml
  .github/discussion-categories.yml docs/operations/code_signing_policy.md
]
required_files.each do |relative|
  path = File.join(ROOT, relative)
  fail_validation("missing #{relative}") unless File.file?(path) && !File.zero?(path)
end

public_text = required_files.map do |relative|
  path = File.join(ROOT, relative)
  File.extname(path).empty? || File.extname(path) == '.md' ? File.read(path) : nil
end.compact.join("\n")
invalid_placeholder_host = ['example', 'invalid'].join('.')
fail_validation('public governance still contains a fake placeholder destination') if public_text.include?(invalid_placeholder_host)

skills = %w[sanad-contribution-triage sanad-pull-request-review sanad-pull-request-lifecycle]
skills.each do |skill|
  path = File.join(ROOT, '.agents/skills', skill, 'SKILL.md')
  fail_validation("missing skill #{skill}") unless File.file?(path)
  text = File.read(path)
  fail_validation("invalid frontmatter for #{skill}") unless text.match?(/\A---\nname: .+\ndescription: .+\n---\n/)
  fail_validation("#{skill} lacks an explicit no-unauthorized-mutation boundary") unless text.downcase.include?('explicit authorization')
end

active_skills = Dir.glob(File.join(ROOT, '.agents/skills/**/SKILL.md')).map { |path| File.read(path) }.join("\n")
fail_validation('ClickUp remains in active public skills') if active_skills.match?(/clickup/i)

setup_fvm = File.read(File.join(ROOT, '.github/actions/setup-fvm/action.yml'))
fail_validation('FVM setup must invoke the activated executable directly') unless setup_fvm.include?('"$PUB_CACHE/bin/fvm" install')
fail_validation('FVM setup uses the removed implicit package entrypoint') if setup_fvm.include?('dart pub global run fvm install')

workflow = File.read(File.join(ROOT, '.github/workflows/ci.yml'))
%w[classify history sensitive-review all-required].each do |job|
  fail_validation("CI is missing #{job} job") unless workflow.match?(/^  #{Regexp.escape(job)}:/)
end
fail_validation('aggregate check name is unstable') unless workflow.include?('name: All required checks pass')
fail_validation('CI must rerun review gates when labels change') unless workflow.include?('labeled') && workflow.include?('unlabeled')
fail_validation('fork PRs must not use pull_request_target') if workflow.include?('pull_request_target')

puts "Governance artifacts valid: #{labels.length} labels, #{yaml_paths.length} YAML files, #{skills.length} contribution skills."
