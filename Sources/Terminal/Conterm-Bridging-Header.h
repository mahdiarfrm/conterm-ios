//
//  Conterm-Bridging-Header.h
//
//  libghostty and libssh2 are both plain C. Rather than wrap either in a
//  Swift package, the app imports their headers directly — the same thing
//  Conterm does on macOS with GhosttyKit's module map, minus the module.
//
//  ghostty.h here is the *patched* one: it declares
//  `ghostty_surface_write_output` and the external-termio callbacks, which
//  upstream libghostty does not have. See patches/ghostty/.
//

#import <ghostty.h>
#import <libssh2.h>
