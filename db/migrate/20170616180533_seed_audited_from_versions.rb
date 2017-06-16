# frozen_string_literal: true
class SeedAuditedFromVersions < ActiveRecord::Migration[5.1]
  IGNORED = ['id', 'order', 'token', 'created_at', 'updated_at', 'last_seen_at', 'last_login_at'].freeze

  class Version < ActiveRecord::Base
    self.table_name = 'versions'
  end

  class Audit < ActiveRecord::Base
  end

  def up
    Version.distinct.pluck(:item_type, :item_id).each do |type, id|
      previous_version = nil
      @number = 0

      Version.where(item_type: type, item_id: id).find_each do |version|
        create_audit(previous_version, version.object) if previous_version
        previous_version = version
      end

      # can fail if class is not defined, but then we treat it as deleted ...
      current = (previous_version.event == "destroy" ? "{}" : current_state(type, id))
      create_audit(previous_version, current)
    end
  end

  def down
    Audit.where(request_uuid: 'migrated').delete_all
  end

  private

  def current_state(type, id)
    if model = type.constantize.unscoped.find_by_id(id)
      attributes = model.attributes
      begin
        attributes['script'] ||= model.script if type == "Stage"
        attributes['next_stage_ids'] = model.next_stage_ids.to_yaml if type == "Stage"
        attributes['project_roles'] = model.send(:role_hash, model.user_project_roles) if type == "User"
      rescue
        puts "Error dumping complex current state for #{type}:#{id} -- #{$!}"
      end
      attributes.to_yaml
    else
      :bad
    end
  rescue NameError
    puts "Unable to find constant #{type} -- #{$!} -- #{$!.class}"
    :bad
  end

  def create_audit(version, current_state)
    diff =
      if current_state == :bad
        {}
      else
        previous_state = YAML.load(version.object || "{}").except(*IGNORED) # rubocop:disable Security/YAMLLoad
        current_state = YAML.load(current_state || "{}").except(*IGNORED) # # rubocop:disable Security/YAMLLoad

        # audited has a strange behavior where the create/destroy changes don't have arrays but just a value
        simple = ["create", "destroy"].include?(version.event)
        simple ? current_state : hash_change(previous_state, current_state)
      end

    return if diff == {} && version.event == "update"

    if version.whodunnit =~ /^\d+$/
      user_id = version.whodunnit
      username = nil
    else
      user_id = nil
      username = version.whodunnit
    end

    Audit.create!(
      auditable_id: version.item_id,
      auditable_type: version.item_type,
      user_id: user_id,
      user_type: "User",
      username: username,
      action: version.event,
      audited_changes: diff.to_yaml,
      version: @number,
      created_at: version.created_at,
      request_uuid: 'migrated'
    )

    @number += 1
  rescue
    puts "ERROR processing #{version.id} (#{version.item_type}:#{version.item_id}) -- #{$!}"
    puts $!.backtrace.select { |l| l.include?(__FILE__) }
    abort
  end

  # {a: 1}, {a:2, b:3} -> {a: [1, 2], b: [nil, 3]}
  def hash_change(before, after)
    (after.keys + before.keys).uniq.each_with_object({}) do |k, change|
      change[k] = [before[k], after[k]] unless before[k] == after[k]
    end
  end
end
