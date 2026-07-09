extends Node3D

## Marble Run toy: marbles drip from the top and cascade down a zig-zag of
## alternately-tilted ramps into the tray at the bottom. Just rolling balls on
## ramps -- no tricks. Shoot more marbles in with F.
##
## Spawning is handled by an Emitter node (Box3DWorld/Emitter, see
## common/emitter.gd) sitting at the top of the first ramp -- move that node
## in the editor to relocate the drip point, no code changes needed here.
