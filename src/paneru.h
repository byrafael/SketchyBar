#pragma once
#include <stdbool.h>
#include <stdint.h>

// Paneru (https://github.com/karinushka/paneru) keeps several virtual
// workspaces inside one macOS Space. With `--bar workspace_source=paneru`,
// space items follow those virtual workspaces instead of Mission Control
// spaces: `associated_space=N` names Paneru workspace N on the display's
// current native Space, and `space_windows_change` reports Paneru's windows.
//
// A background thread follows `paneru subscribe` and re-reads
// `paneru query state` when the workspace rows change. Everything else here
// runs on the main thread.

struct paneru_state;

// Starts or stops following Paneru. Returns true when the mode changed.
bool paneru_set_enabled(bool enabled);
bool paneru_enabled(void);

// The Paneru workspace number shown on the native Space `dsid`, or 0 when
// Paneru reports none.
uint32_t paneru_selected_workspace(uint64_t dsid);

// Whether Paneru has workspace `number` on the native Space `dsid`.
bool paneru_has_workspace(uint64_t dsid, uint32_t number);

// Takes ownership of a state read by the background thread.
void paneru_handle_state(struct paneru_state* state);

// Sends `space_windows_change` for each Paneru workspace on a native Space a
// bar shows. Unless `forced`, only workspaces whose app list changed since
// the last call are sent.
void paneru_post_space_windows(bool forced);
