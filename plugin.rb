# name: civically-group-extension
# about: Civically Group extension
# version: 0.1
# authors: angus
# url: https://github.com/civicallyhq/x-civically-group

register_asset 'stylesheets/civically-group.scss'

after_initialize do
  Group.register_custom_field_type('category_id', :integer)
  Group.preloaded_custom_fields << "category_id" if Group.respond_to? :preloaded_custom_fields

  ## 'migration' to be wrapped in conditional
  CustomWizard::Wizard.add_wizard(File.read(File.join(
    Rails.root, 'plugins', 'x-civically-group', 'config', 'wizards', 'group_petition.json'
  )))

  CustomWizard::Builder.add_step_handler('group_petition') do |builder|
    if builder.updater && builder.updater.step && builder.updater.step.id === 'profile'
      updater = builder.updater

      validator = UsernameValidator.new(updater.fields['name'])
      unless validator.valid_format?
        validator.errors.each { |e|
          updater.errors.add(:group_petition, "Name #{e}")
        }
      end
    end
  end

  require_dependency 'guardian'
  Guardian.class_eval do
    def can_log_group_changes?(group)
      is_admin? ||
      group.users.where('group_users.owner').include?(user) ||
      group.custom_fields['category_id'].to_i === @user.moderator_category_id.to_i
    end
  end

  require_dependency 'staff_constraint'
  Discourse::Application.routes.append do
    namespace :admin, constraints: StaffConstraint.new do
      post "groups" => "groups#create"
      get "groups/:type" => "groups#show", constraints: { type: 'custom' }
      get "groups/:type/:id" => "groups#show", constraints: { type: 'custom' }
      put "groups/:id" => "groups#update"
    end

    get "c/:parent_category/:category/groups" => "groups#show"
  end

  module GroupsControllerExtension
    def save_group(group)
      if group_params[:custom_fields]
        group_params[:custom_fields].permit(:category_id)

        group_params[:custom_fields].each do |key, value|
          group.custom_fields[key] = value
        end

        if group.custom_fields['category_id']
          Jobs.enqueue(:bulk_unread_lists_update,
            place_category_id: group.custom_fields['category_id'],
            add_lists: ['group']
          )
        end
      end
      super(group)
    end

    private def group_params
      params.require(:group).permit(
        :name,
        :mentionable_level,
        :messageable_level,
        :visibility_level,
        :automatic_membership_email_domains,
        :automatic_membership_retroactive,
        :title,
        :primary_group,
        :grant_trust_level,
        :incoming_email,
        :flair_url,
        :flair_bg_color,
        :flair_color,
        :bio_raw,
        :public_admission,
        :public_exit,
        :allow_membership_requests,
        :full_name,
        :default_notification_level,
        :usernames,
        :owner_usernames,
        :membership_request_template,
        custom_fields: [:category_id]
      )
    end
  end

  require_dependency 'admin/groups_controller'
  class Admin::GroupsController
    prepend GroupsControllerExtension
  end

  GroupsController.class_eval do
    def search
      groups = Group.visible_groups(current_user)
        .where("groups.id <> ?", Group::AUTO_GROUPS[:everyone])
        .order(:name)

      if term = params[:term].to_s
        groups = groups.where("name ILIKE :term OR full_name ILIKE :term", term: "%#{term}%")
      end

      if category_id = params[:category_id]
        groups = groups.select { |g| g.custom_fields['category_id'].to_i === category_id.to_i }
      end

      if meta = params[:meta] === 'true'
        groups = groups.select { |g| !g.custom_fields['category_id'] }
      end

      if params[:ignore_automatic].to_s == "true"
        groups = groups.where(automatic: false)
      end

      if Group.preloaded_custom_field_names.present?
        Group.preload_custom_fields(groups, Group.preloaded_custom_field_names)
      end

      render_serialized(groups, BasicGroupSerializer)
    end
  end

  add_to_serializer(:basic_group, :category_id) { object.custom_fields["category_id"] }
  add_to_serializer(:basic_group, :custom_fields) { object.custom_fields }
  add_to_serializer(:basic_group, :url) { "/groups/#{object.name}" }
end
