export default {
  setupComponent(attrs, component) {
    if (!attrs.group.custom_fields) {
      component.set('group.custom_fields', {});
    }
  }
};
