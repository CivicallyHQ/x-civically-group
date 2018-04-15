export default {
  setupComponent(attrs, component) {
    if (!attrs.group.custom_fields) {
      component.set('group.custom_fields', {});
    }
    const places = this.site.get('categories').filter((c) => c.is_place);
    const user = this.currentUser;
    let availablePlaces = null;
    if (user.admin) {
      availablePlaces = places;
    } else {
      availablePlaces = [places.findBy('id', user.moderator_category_id)];
    }
    component.set('availablePlaces', availablePlaces);
  }
};
