# Ember Connect Mobile runtime

Ember Connect Mobile incorporates and modifies LiveContainer 3.8.0:

- Upstream: https://github.com/LiveContainer/LiveContainer
- Pinned tag: `3.8.0`
- Pinned commit: `e370a92dfc03ce109ebce00ed4a7cfc64ad1c801`
- Upstream license: GNU Affero General Public License v3.0

Ember-specific changes add the desktop `Documents/AutoInstall` inbox,
automatic signing-certificate import, Ember branding, and ReplayKit screen
mirroring. The optional LiveContainer multitasking, launch, and share
extensions are removed from the packaged IPA so they do not consume extra App
IDs. The complete corresponding source used to build the app is included in
`LiveContainerRuntime/`.

The root `LICENSE` applies to this combined iOS application. Individual
third-party components retain their own license and notice files inside
`LiveContainerRuntime/`.
