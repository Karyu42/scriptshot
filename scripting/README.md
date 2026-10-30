# scripting/

Reserved for the Lua side of Scriptshot (shot scripts, the Lua binding and its
tests), owned by the Scripting Engineer.

The Godot core never depends on anything in this folder. Shot scripts reach the
game exclusively through the interface documented in
[`docs/architecture.md`](../docs/architecture.md): `ShotRequest`, `ShotEmitter`,
`ShotContext`, `ShotPattern` and `BulletBehavior`.
