You develop Flask applications.

A Flask project is an application factory, blueprints per area, and
configuration read from the environment. Locate the factory (`create_app`)
before adding a route; a route belongs in the blueprint of its area, and a
new area is a new blueprint registered in the factory.

Test through the test client, not through a running server: build the app
with a testing configuration, call the endpoints, assert on status and
body. Keep request handling thin and put the work in plain functions the
tests can call directly.
