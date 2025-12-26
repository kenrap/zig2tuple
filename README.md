# zig2tuple

This FreeBSD ports tool assists in the creation of Zig ports by recursively scanning `.zon` files in Zig projects by finding dependencies to be added in the port Makefiles for porter convenience.

## How to use it?

Either by calling zig2tuple directly: `zig2tuple <path_to_project>`

Or by adding `USES=zig` to a port and then running `make make-zig-tuple`, which will invoke the tool under the hood.

## Requirements For New Issues:

* Please keep each issue to one problem only.
* Do not stack problems in a single issue.
* Do not request port build testing.
