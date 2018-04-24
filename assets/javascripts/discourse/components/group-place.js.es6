export default Ember.Component.extend({
  didInsertElement() {
    Ember.run.scheduleOnce('afterRender', () => {
      this.$().parent().appendTo('.group-info');
    })
  }
})
