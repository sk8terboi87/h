'use strict';

var inherits = require('inherits');

var Controller = require('../../base/controller');

function TestController(element) {
  Controller.call(this, element);

  this.update = sinon.stub();
}
inherits(TestController, Controller);

describe('Controller', function () {
  var ctrl;

  beforeEach(function () {
    var root = document.createElement('div');
    root.dataset.ref = 'test';
    document.body.appendChild(root);
    ctrl = new TestController(root);
  });

  afterEach(function () {
    ctrl.element.remove();
  });

  it('exposes controllers via the `.controllers` element property', function () {
    assert.equal(ctrl.element.controllers.length, 1);
    assert.instanceOf(ctrl.element.controllers[0], TestController);
  });

  it('exposes elements with "data-ref" attributes on the `refs` property', function () {
    assert.deepEqual(ctrl.refs, {test: ctrl.element});
  });

  describe('#setState', function () {
    it('calls update() with new and previous state', function () {
      ctrl.setState({open: true});
      ctrl.update = sinon.stub();
      ctrl.setState({open: true, saving: true});
      assert.calledWith(ctrl.update, {
        open: true,
        saving: true,
      }, {
        open: true,
      });
    });
  });
});