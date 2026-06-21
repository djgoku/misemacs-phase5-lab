/* misemacs-jinx-enchant-env.h -- native env bridge for bundled jinx/enchant.

   Emacs Lisp `setenv' updates Emacs's process-environment for subprocesses, but
   native modules do not see it through libc getenv(3).  Jinx calls
   enchant_broker_init() from jinx-mod.dylib, so force-including this header makes
   that native call publish ENCHANT_CONFIG_DIR before libenchant initializes. */

#ifndef MISEMACS_JINX_ENCHANT_ENV_H
#define MISEMACS_JINX_ENCHANT_ENV_H

#include <stdlib.h>
#include <enchant.h>

#define MISEMACS_JINX_ENCHANT_ENV_MARKER "misemacs-jinx-enchant-env/1"

__attribute__((used))
static const char misemacs_jinx_enchant_env_marker[] =
    MISEMACS_JINX_ENCHANT_ENV_MARKER;

static inline EnchantBroker *misemacs_jinx_enchant_broker_init(void) {
#ifdef MISEMACS_ENCHANT_CONFIG_DIR
  static int configured;
  if (!configured) {
    setenv("ENCHANT_CONFIG_DIR", MISEMACS_ENCHANT_CONFIG_DIR, 1);
    configured = 1;
  }
#endif

  return enchant_broker_init();
}

#define enchant_broker_init misemacs_jinx_enchant_broker_init

#endif
