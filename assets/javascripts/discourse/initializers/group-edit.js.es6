import { withPluginApi } from 'discourse/lib/plugin-api';
import Group from 'discourse/models/group';
import GroupsIndexRoute from 'discourse/routes/groups-index';
import GroupsIndexController from 'discourse/controllers/groups-index';

export default {
  name: 'group-edit',
  initialize(container) {
    const currentUser = container.lookup('current-user:main');

    withPluginApi('0.8.12', api => {
      if (currentUser && currentUser.staff) {
        api.modifyClass('route:admin-groups-type', {
          model(params) {
            this.set("type", params.type);
            const user = this.currentUser;
            let opts = {};

            if (!user.admin) {
              opts['category_id'] = user.moderator_category_id;
            }

            return Group.findAll(opts).then(function(gs) {
              return gs.filterBy("type", params.type);
            });
          }
        });
      }

      api.modifyClass('model:group', {
        asJSON() {
          let attrs = this._super();
          attrs['custom_fields'] = this.get('custom_fields');
          return attrs;
        }
      });

      api.modifyClass('route:groups-index', {
        queryParams: Object.assign({}, GroupsIndexRoute.queryParams, {
          category_id: { refreshModel: true },
          meta: { refreshModel: true }
        }),

        redirect(model, transition) {
          if (Object.keys(transition.queryParams).length === 0) {
            const placeCategoryId = this.get('currentUser.place_category_id');
            if (placeCategoryId) {
              this.replaceWith({queryParams: { category_id: placeCategoryId }});
            } else {
              this.replaceWith({queryParams: { meta: true }});
            }
          }
        }
      });

      const groupsIndexController = GroupsIndexController.create();
      let existingParams = groupsIndexController.get('queryParams').map((v) => v);
      let queryParams = existingParams.push(...['category_id', 'meta']);
      api.modifyClass('controller:groups-index', { queryParams });
    });
  }
};
