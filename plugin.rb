# name: civically-group-extension
# about: Civically Group extension
# version: 0.1
# authors: angus
# url: https://github.com/civicallyhq/x-civically-group

register_asset 'stylesheets/civically-group.scss'

DiscourseEvent.on(:custom_wizard_ready) do
  if !CustomWizard::Wizard.find('group_petition') || Rails.env.development?
    CustomWizard::Wizard.add_wizard(File.read(File.join(
      Rails.root, 'plugins', 'x-civically-group', 'config', 'wizards', 'group_petition.json'
    )))
  end

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
end

after_initialize do
  Group.register_custom_field_type('category_id', :integer)
  Group.preloaded_custom_fields << "category_id" if Group.respond_to? :preloaded_custom_fields

  module GroupGuardianExtension
    def can_log_group_changes(group)
      super ||
      (@user.category_moderator &&
       @user.moderator_category_ids.include?(group.custom_fields['category_id']))
    end
  end

  require_dependency 'guardian'
  class ::Guardian
    prepend GroupGuardianExtension
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

  module GroupsControllerHelpers
    def filter_groups_by_custom_fields(groups)
      if category_id = params[:category_id]
        groups = groups.where("groups.id in (
          SELECT group_id FROM group_custom_fields WHERE name = 'category_id' AND value = ?
        )", category_id.to_s)
      end

      if params[:meta] === 'true'
        groups = groups.where("groups.id not in (
          SELECT group_id FROM group_custom_fields WHERE name = 'category_id'
        )")
      end

      groups
    end

    def update_group_custom_fields(group)
      if custom_fields = group_params[:custom_fields]
        if custom_fields[:category_id]
          group.custom_fields['category_id'] = custom_fields[:category_id]
        end

        if group.custom_fields['category_id']
          Jobs.enqueue(:bulk_unread_lists_update,
            category_id: group.custom_fields['category_id'],
            add_lists: ['group']
          )
        end

        group.save_custom_fields(true)
      end

      group
    end
  end

  module AdminGroupsControllerExtension
    def create
      attributes = group_params.to_h.except(:owner_usernames, :usernames)
      group = Group.new(attributes)

      unless group_params[:allow_membership_requests]
        group.membership_request_template = nil
      end

      ## Start of Addition
      group = update_group_custom_fields(group)
      ## End of Addition

      if group_params[:owner_usernames].present?
        owner_ids = User.where(
          username: group_params[:owner_usernames].split(",")
        ).pluck(:id)

        owner_ids.each do |user_id|
          group.group_users.build(user_id: user_id, owner: true)
        end
      end

      if group_params[:usernames].present?
        user_ids = User.where(username: group_params[:usernames].split(",")).pluck(:id)
        user_ids -= owner_ids if owner_ids

        user_ids.each do |user_id|
          group.group_users.build(user_id: user_id)
        end
      end

      if group.save
        group.restore_user_count!
        render_serialized(group, BasicGroupSerializer)
      else
        render_json_error group
      end
    end

    private def group_params
      custom_fields = params.require(:group).permit(custom_fields: [:category_id])[:custom_fields]
      super.merge(custom_fields: custom_fields)
    end
  end

  require_dependency 'admin/groups_controller'
  class Admin::GroupsController
    prepend GroupsControllerHelpers
    prepend AdminGroupsControllerExtension
  end

  module GroupsControllerExtension
    def index
      unless SiteSetting.enable_group_directory? || current_user&.staff?
        raise Discourse::InvalidAccess.new(:enable_group_directory)
      end

      page_size = 30
      page = params[:page]&.to_i || 0
      order = %w{name user_count}.delete(params[:order])
      dir = params[:asc] ? 'ASC' : 'DESC'
      groups = Group.visible_groups(current_user, order ? "#{order} #{dir}" : nil)

      ## Start of Addition
      groups = filter_groups_by_custom_fields(groups)
      ## End of Addition

      if (filter = params[:filter]).present?
        groups = Group.search_groups(filter, groups: groups)
      end

      type_filters = GroupsController::TYPE_FILTERS.keys

      if username = params[:username]
        groups = GroupsController::TYPE_FILTERS[:my].call(groups, User.find_by_username(username))
        type_filters = type_filters - [:my, :owner]
      end

      unless guardian.is_staff?
        # hide automatic groups from all non stuff to de-clutter page
        groups = groups.where("automatic IS FALSE OR groups.id = #{Group::AUTO_GROUPS[:moderators]}")
        type_filters.delete(:automatic)
      end

      if Group.preloaded_custom_field_names.present?
        Group.preload_custom_fields(groups, Group.preloaded_custom_field_names)
      end

      if type = params[:type]&.to_sym
        groups = GroupsController::TYPE_FILTERS[type].call(groups, current_user)
      end

      if current_user
        group_users = GroupUser.where(group: groups, user: current_user)
        user_group_ids = group_users.pluck(:group_id)
        owner_group_ids = group_users.where(owner: true).pluck(:group_id)
      else
        type_filters = type_filters - [:my, :owner]
      end

      count = groups.count
      groups = groups.offset(page * page_size).limit(page_size)

      render_json_dump(
        groups: serialize_data(groups,
          BasicGroupSerializer,
          user_group_ids: user_group_ids || [],
          owner_group_ids: owner_group_ids || []
        ),
        extras: {
          type_filters: type_filters
        },
        total_rows_groups: count,
        load_more_groups: groups_path(page: page + 1, type: type),
      )
    end

    def show
      respond_to do |format|
        group = find_group(:id)

        format.html do
          @title = group.full_name.present? ? group.full_name.capitalize : group.name
          @description_meta = group.bio_cooked.present? ? PrettyText.excerpt(group.bio_cooked, 300) : @title
          render :show
        end

        format.json do
          groups = Group.visible_groups(current_user)

          ## Start of Addition
          if town_category_id = current_user.town_category_id
            town_groups = groups.where("groups.id in (
              SELECT group_id FROM group_custom_fields WHERE name = 'category_id' AND value = ?
            )", town_category_id.to_s)

            if neighbourhood_category_id = current_user.neighbourhood_category_id
              neighbourhood_groups = groups.where("groups.id in (
                SELECT group_id FROM group_custom_fields WHERE name = 'category_id' AND value = ?
              )", neighbourhood_category_id.to_s)

              groups = groups.from("(#{town_groups.to_sql} UNION #{neighbourhood_groups.to_sql}) AS groups")
            else
              groups = town_groups
            end
          else
            groups = groups.where("groups.id not in (
              SELECT group_id FROM group_custom_fields WHERE name = 'category_id'
            )")
          end
          ## End of Addition

          if !guardian.is_staff?
            groups = groups.where(automatic: false)
          end

          render_json_dump(
            group: serialize_data(group, ::GroupShowSerializer, root: nil),
            extras: {
              visible_group_names: groups.pluck(:name)
            }
          )
        end
      end
    end

    def update
      group = Group.find(params[:id])
      guardian.ensure_can_edit!(group) unless current_user.admin

      ## Start of Addition
      group = update_group_custom_fields(group)
      ## End of Addition

      super
    end

    def search
      groups = Group.visible_groups(current_user)
        .where("groups.id <> ?", Group::AUTO_GROUPS[:everyone])
        .order(:name)

      if term = params[:term].to_s
        groups = groups.where("name ILIKE :term OR full_name ILIKE :term", term: "%#{term}%")
      end

      ## Start of Addition
      groups = filter_groups_by_custom_fields(groups)
      ## End of Addition

      if params[:ignore_automatic].to_s == "true"
        groups = groups.where(automatic: false)
      end

      if Group.preloaded_custom_field_names.present?
        Group.preload_custom_fields(groups, Group.preloaded_custom_field_names)
      end

      render_serialized(groups, BasicGroupSerializer)
    end

    private def group_params(automatic: false)
      custom_fields = params.require(:group).permit(custom_fields: [:category_id])[:custom_fields]
      super(automatic: false).merge(custom_fields: custom_fields)
    end
  end

  require_dependency 'groups_controller'
  class ::GroupsController
    prepend GroupsControllerHelpers
    prepend GroupsControllerExtension
  end

  add_to_serializer(:basic_group, :category_id) { object.custom_fields["category_id"] }
  add_to_serializer(:basic_group, :custom_fields) { object.custom_fields }
  add_to_serializer(:basic_group, :url) { "/groups/#{object.name}" }
end
