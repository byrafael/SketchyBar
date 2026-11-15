#include "paneru.h"
#include "bar_manager.h"
#include "event.h"
#include "misc/helpers.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <time.h>
#include <unistd.h>

#import <Foundation/Foundation.h>

extern char** environ;
extern struct bar_manager g_bar_manager;

// How long a burst of subscription events may run before the rows are read
// again. Paneru sends several events per window move.
#define PANERU_COALESCE_MS 40
// A query that takes longer than this belongs to a stuck daemon.
#define PANERU_QUERY_TIMEOUT_MS 2000
#define PANERU_RETRY_MIN_S 1
#define PANERU_RETRY_MAX_S 8

struct paneru_row {
  uint32_t number;
  uint64_t native_id;
  bool active;
  bool selected;
  // The payload `space_windows_change` sends for this row, minus the
  // per-display fields. Compared to decide whether the row changed.
  char* apps_json;
};

struct paneru_state {
  uint64_t generation;
  struct paneru_row* rows;
  uint32_t row_count;
};

// What was last sent for one workspace number on one display.
struct paneru_sent {
  uint32_t adid;
  uint32_t number;
  uint64_t native_id;
  char* apps_json;
};

// Main thread only.
static struct paneru_state* g_state = NULL;
static struct paneru_sent* g_sent = NULL;
static uint32_t g_sent_count = 0;

// Shared with the reader thread, guarded by g_lock.
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static bool g_enabled = false;
// Bumped on every mode change, so a state read before it is dropped.
static uint64_t g_generation = 0;
static pid_t g_child = 0;
static bool g_thread_started = false;

static void paneru_state_destroy(struct paneru_state* state) {
  if (!state) return;
  for (uint32_t i = 0; i < state->row_count; i++) {
    free(state->rows[i].apps_json);
  }
  free(state->rows);
  free(state);
}

static void paneru_sent_clear(void) {
  for (uint32_t i = 0; i < g_sent_count; i++) free(g_sent[i].apps_json);
  free(g_sent);
  g_sent = NULL;
  g_sent_count = 0;
}

static void json_append_string(NSMutableString* out, NSString* string) {
  [out appendString:@"\""];
  NSUInteger length = [string length];
  for (NSUInteger i = 0; i < length; i++) {
    unichar c = [string characterAtIndex:i];
    switch (c) {
      case '"':  [out appendString:@"\\\""]; break;
      case '\\': [out appendString:@"\\\\"]; break;
      case '\n': [out appendString:@"\\n"];  break;
      case '\r': [out appendString:@"\\r"];  break;
      case '\t': [out appendString:@"\\t"];  break;
      default:
        if (c < 0x20) [out appendFormat:@"\\u%04x", c];
        else [out appendFormat:@"%C", c];
    }
  }
  [out appendString:@"\""];
}

// `{"Name": count, ...}` in the order the apps first appear on the row, which
// is Paneru's left-to-right strip order.
static char* paneru_apps_json(NSArray* windows) {
  NSMutableArray* names = [NSMutableArray array];
  NSMutableDictionary* counts = [NSMutableDictionary dictionary];
  if ([windows isKindOfClass:[NSArray class]]) {
    for (id window in windows) {
      if (![window isKindOfClass:[NSDictionary class]]) continue;
      id name = window[@"app_name"];
      if (![name isKindOfClass:[NSString class]] || [name length] == 0) continue;
      NSNumber* count = counts[name];
      if (!count) [names addObject:name];
      counts[name] = @([count unsignedIntValue] + 1);
    }
  }

  NSMutableString* out = [NSMutableString stringWithString:@"{"];
  for (NSUInteger i = 0; i < [names count]; i++) {
    [out appendString:i == 0 ? @"\n\t\t" : @",\n\t\t"];
    json_append_string(out, names[i]);
    [out appendFormat:@": %u", [counts[names[i]] unsignedIntValue]];
  }
  [out appendString:[names count] ? @"\n\t}" : @"}"];
  return string_copy((char*)[out UTF8String]);
}

static bool json_bool(id value, bool fallback) {
  return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

// Parses `paneru query state`. Returns NULL for anything that is not a state
// document.
static struct paneru_state* paneru_state_parse(NSData* data, uint64_t generation) {
  @autoreleasepool {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) return NULL;
    NSArray* rows = root[@"virtual_workspaces"];
    if (![rows isKindOfClass:[NSArray class]]) return NULL;

    struct paneru_state* state = calloc(1, sizeof(struct paneru_state));
    state->generation = generation;
    state->rows = calloc([rows count] ? [rows count] : 1, sizeof(struct paneru_row));

    for (id row in rows) {
      if (![row isKindOfClass:[NSDictionary class]]) continue;
      id number = row[@"number"];
      id native_id = row[@"native_workspace_id"];
      if (![number isKindOfClass:[NSNumber class]]
          || ![native_id isKindOfClass:[NSNumber class]]) {
        continue;
      }

      struct paneru_row* out = &state->rows[state->row_count++];
      out->number = [number unsignedIntValue];
      out->native_id = [native_id unsignedLongLongValue];
      out->active = json_bool(row[@"active"], false);
      // Daemons before `selected` existed only report the active row.
      out->selected = json_bool(row[@"selected"], out->active);
      out->apps_json = paneru_apps_json(row[@"windows"]);
    }
    return state;
  }
}

static char* paneru_find_binary(void) {
  char* path = getenv("PATH");
  if (path) {
    char* paths = string_copy(path);
    char* saveptr = NULL;
    for (char* dir = strtok_r(paths, ":", &saveptr);
         dir;
         dir = strtok_r(NULL, ":", &saveptr)) {
      char candidate[PATH_MAX];
      snprintf(candidate, sizeof(candidate), "%s/paneru", dir);
      if (access(candidate, X_OK) == 0) {
        free(paths);
        return string_copy(candidate);
      }
    }
    free(paths);
  }

  // launchd starts the bar with a minimal PATH that misses Cargo's bin.
  char cargo[PATH_MAX] = { 0 };
  char* home = getenv("HOME");
  if (home) snprintf(cargo, sizeof(cargo), "%s/.cargo/bin/paneru", home);
  char* fallbacks[] = { cargo, "/opt/homebrew/bin/paneru", "/usr/local/bin/paneru" };
  for (int i = 0; i < sizeof(fallbacks) / sizeof(*fallbacks); i++) {
    if (fallbacks[i][0] && access(fallbacks[i], X_OK) == 0) {
      return string_copy(fallbacks[i]);
    }
  }
  return NULL;
}

// Runs `paneru <args...>` with its stdout on a pipe. Returns the child pid, or
// 0 on failure.
//
// The bar ignores SIGCHLD, so the kernel reaps children and `waitpid` would
// block while any child lives. A child is only signalled while its pipe is
// still open, which means it has not exited and its pid is still its own.
static pid_t paneru_spawn(char* binary, char** args, int* out_fd) {
  int fds[2];
  if (pipe(fds) != 0) return 0;
  // Keep the pipe out of the bar's own script children, so the read end sees
  // EOF when Paneru exits.
  fcntl(fds[0], F_SETFD, FD_CLOEXEC);
  fcntl(fds[1], F_SETFD, FD_CLOEXEC);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

  pid_t pid = 0;
  int result = posix_spawn(&pid, binary, &actions, NULL, args, environ);
  posix_spawn_file_actions_destroy(&actions);
  close(fds[1]);

  if (result != 0) {
    close(fds[0]);
    return 0;
  }
  *out_fd = fds[0];
  return pid;
}

static uint64_t paneru_current_generation(void) {
  pthread_mutex_lock(&g_lock);
  uint64_t generation = g_generation;
  pthread_mutex_unlock(&g_lock);
  return generation;
}

static void paneru_post_state(struct paneru_state* state) {
  struct event event = { state, PANERU_STATE_CHANGED };
  event_post(&event);
}

// Reads the full state document and hands it to the main thread. Returns
// false when Paneru did not answer with one.
static bool paneru_refresh(char* binary, uint64_t generation) {
  char* args[] = { binary, "query", "state", NULL };
  int fd;
  pid_t pid = paneru_spawn(binary, args, &fd);
  if (!pid) return false;

  struct paneru_state* state = NULL;
  @autoreleasepool {
    NSMutableData* data = [NSMutableData data];
    char buffer[16384];
    for (;;) {
      struct pollfd pfd = { fd, POLLIN, 0 };
      int ready = poll(&pfd, 1, PANERU_QUERY_TIMEOUT_MS);
      if (ready < 0 && errno == EINTR) continue;
      if (ready <= 0) {
        // Still running, so the pid is still Paneru's.
        kill(pid, SIGTERM);
        [data setLength:0];
        break;
      }
      ssize_t n = read(fd, buffer, sizeof(buffer));
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) break;
      [data appendBytes:buffer length:n];
    }
    close(fd);

    if ([data length]) state = paneru_state_parse(data, generation);
  }

  if (!state) return false;
  paneru_post_state(state);
  return true;
}

// How soon after a subscription line the rows should be read again, or -1
// when the line cannot change them. A workspace switch is shown at once.
// Window list changes arrive in bursts during an animation, so they wait a
// moment and share one read. Moves, resizes, focus and titles never change
// which apps a row holds.
static int paneru_line_delay_ms(char* line, size_t length) {
  static const struct { char* name; int delay_ms; } events[] = {
    { "virtual_workspace_changed", 0 },
    { "display_changed", 0 },
    { "windows_changed", PANERU_COALESCE_MS },
  };

  // Most lines are frame updates; skip parsing those.
  bool candidate = false;
  for (int i = 0; i < sizeof(events) / sizeof(*events); i++) {
    if (memmem(line, length, events[i].name, strlen(events[i].name))) {
      candidate = true;
      break;
    }
  }
  if (!candidate) return -1;

  @autoreleasepool {
    NSData* data = [NSData dataWithBytesNoCopy:line length:length freeWhenDone:NO];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) return -1;
    id event = root[@"event"];
    if (![event isKindOfClass:[NSString class]]) return -1;
    for (int i = 0; i < sizeof(events) / sizeof(*events); i++) {
      if (strcmp([event UTF8String], events[i].name) == 0) return events[i].delay_ms;
    }
    return -1;
  }
}

static int64_t paneru_now_ms(void) {
  return (int64_t)(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000);
}

struct line_reader {
  char* buffer;
  size_t length;
  size_t capacity;
  // When the rows must be read again, or -1 when nothing asked for it.
  int64_t refresh_at_ms;
};

// Reads what is available on `fd` and moves the refresh deadline forward for
// each line that asks for one. Returns false at EOF or on error.
static bool paneru_read_lines(int fd, struct line_reader* reader) {
  if (reader->capacity - reader->length < 4096) {
    reader->capacity = reader->capacity * 2 + 4096;
    reader->buffer = realloc(reader->buffer, reader->capacity);
  }

  ssize_t n;
  do {
    n = read(fd, reader->buffer + reader->length, reader->capacity - reader->length);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) return false;
  reader->length += n;

  size_t start = 0;
  for (size_t i = 0; i < reader->length; i++) {
    if (reader->buffer[i] != '\n') continue;
    int delay_ms = i > start
                   ? paneru_line_delay_ms(reader->buffer + start, i - start)
                   : -1;
    if (delay_ms >= 0) {
      int64_t at = paneru_now_ms() + delay_ms;
      if (reader->refresh_at_ms < 0 || at < reader->refresh_at_ms) {
        reader->refresh_at_ms = at;
      }
    }
    start = i + 1;
  }
  memmove(reader->buffer, reader->buffer + start, reader->length - start);
  reader->length -= start;
  return true;
}

// Follows one `paneru subscribe` session until it ends. Returns whether the
// session produced a state.
static bool paneru_follow(char* binary, uint64_t generation) {
  char* args[] = { binary, "subscribe", NULL };
  int fd;
  pid_t pid = paneru_spawn(binary, args, &fd);
  if (!pid) return false;

  pthread_mutex_lock(&g_lock);
  bool current = g_enabled && g_generation == generation;
  if (current) g_child = pid;
  pthread_mutex_unlock(&g_lock);

  bool connected = false;
  if (!current) kill(pid, SIGTERM);
  else {
    // Subscribe first, then read, so a change between the two is not lost.
    connected = paneru_refresh(binary, generation);

    struct line_reader reader = { .refresh_at_ms = -1 };
    for (;;) {
      int timeout_ms = -1;
      if (reader.refresh_at_ms >= 0) {
        int64_t wait = reader.refresh_at_ms - paneru_now_ms();
        timeout_ms = wait > 0 ? (int)wait : 0;
      }

      struct pollfd pfd = { fd, POLLIN, 0 };
      int ready = poll(&pfd, 1, timeout_ms);
      if (ready < 0 && errno != EINTR) break;
      if (ready > 0 && !paneru_read_lines(fd, &reader)) break;

      if (reader.refresh_at_ms >= 0 && paneru_now_ms() >= reader.refresh_at_ms) {
        reader.refresh_at_ms = -1;
        connected |= paneru_refresh(binary, generation);
      }
    }
    free(reader.buffer);
  }

  pthread_mutex_lock(&g_lock);
  if (g_child == pid) g_child = 0;
  pthread_mutex_unlock(&g_lock);

  // The read loop ends at EOF, when `paneru subscribe` has exited.
  close(fd);
  return connected;
}

static void* paneru_reader(void* context) {
  unsigned int retry = PANERU_RETRY_MIN_S;
  for (;;) {
    pthread_mutex_lock(&g_lock);
    while (!g_enabled) pthread_cond_wait(&g_cond, &g_lock);
    uint64_t generation = g_generation;
    pthread_mutex_unlock(&g_lock);

    char* binary = paneru_find_binary();
    bool connected = binary && paneru_follow(binary, generation);
    free(binary);

    // Paneru is gone or never answered: show no workspaces rather than stale
    // ones until it is back.
    if (paneru_current_generation() != generation) {
      // The mode changed under us (a config reload): reconnect right away.
      retry = PANERU_RETRY_MIN_S;
      continue;
    }
    struct paneru_state* empty = calloc(1, sizeof(struct paneru_state));
    empty->generation = generation;
    paneru_post_state(empty);

    retry = connected ? PANERU_RETRY_MIN_S
                      : (retry * 2 > PANERU_RETRY_MAX_S ? PANERU_RETRY_MAX_S
                                                        : retry * 2);
    sleep(retry);
  }
  return NULL;
}

static void paneru_stop_child(void) {
  pthread_mutex_lock(&g_lock);
  if (g_child > 0) kill(g_child, SIGTERM);
  pthread_mutex_unlock(&g_lock);
}

bool paneru_set_enabled(bool enabled) {
  pthread_mutex_lock(&g_lock);
  if (g_enabled == enabled) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  g_enabled = enabled;
  g_generation++;
  if (g_child > 0) kill(g_child, SIGTERM);
  if (enabled && !g_thread_started) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, paneru_reader, NULL) == 0) {
      pthread_detach(thread);
      g_thread_started = true;
      atexit(paneru_stop_child);
    }
  }
  pthread_cond_broadcast(&g_cond);
  pthread_mutex_unlock(&g_lock);

  paneru_state_destroy(g_state);
  g_state = NULL;
  paneru_sent_clear();
  return true;
}

bool paneru_enabled(void) {
  pthread_mutex_lock(&g_lock);
  bool enabled = g_enabled;
  pthread_mutex_unlock(&g_lock);
  return enabled;
}

uint32_t paneru_selected_workspace(uint64_t dsid) {
  if (!g_state) return 0;
  uint32_t selected = 0;
  for (uint32_t i = 0; i < g_state->row_count; i++) {
    struct paneru_row* row = &g_state->rows[i];
    if (row->native_id != dsid) continue;
    if (row->active) return row->number;
    if (row->selected && !selected) selected = row->number;
  }
  return selected;
}

bool paneru_has_workspace(uint64_t dsid, uint32_t number) {
  if (!g_state) return false;
  for (uint32_t i = 0; i < g_state->row_count; i++) {
    if (g_state->rows[i].native_id == dsid && g_state->rows[i].number == number) {
      return true;
    }
  }
  return false;
}

void paneru_handle_state(struct paneru_state* state) {
  if (!paneru_enabled() || state->generation != paneru_current_generation()) {
    paneru_state_destroy(state);
    return;
  }

  paneru_state_destroy(g_state);
  g_state = state;
  // Recomputes each bar's workspace and the space items, then sends
  // `space_change` and `space_windows_change`.
  bar_manager_handle_space_change(&g_bar_manager, false);
}

static struct paneru_sent* paneru_sent_find(uint32_t adid, uint32_t number) {
  for (uint32_t i = 0; i < g_sent_count; i++) {
    if (g_sent[i].adid == adid && g_sent[i].number == number) return &g_sent[i];
  }
  return NULL;
}

void paneru_post_space_windows(bool forced) {
  if (!g_state) return;

  for (uint32_t b = 0; b < g_bar_manager.bar_count; b++) {
    struct bar* bar = g_bar_manager.bars[b];
    for (uint32_t i = 0; i < g_state->row_count; i++) {
      struct paneru_row* row = &g_state->rows[i];
      if (row->native_id != bar->dsid) continue;

      struct paneru_sent* sent = paneru_sent_find(bar->adid, row->number);
      bool changed = !sent
                     || sent->native_id != row->native_id
                     || strcmp(sent->apps_json, row->apps_json) != 0;
      if (!changed && !forced) continue;

      if (!sent) {
        g_sent = realloc(g_sent, sizeof(struct paneru_sent) * ++g_sent_count);
        sent = &g_sent[g_sent_count - 1];
        sent->adid = bar->adid;
        sent->number = row->number;
        sent->apps_json = NULL;
      }
      sent->native_id = row->native_id;
      free(sent->apps_json);
      sent->apps_json = string_copy(row->apps_json);

      // The same keys as the native event, plus the display, because each
      // display has its own workspace 1.
      size_t length = strlen(row->apps_json) + 96;
      char payload[length];
      snprintf(payload, length, "{\n"
                                "\t\"space\": %u,\n"
                                "\t\"display\": %u,\n"
                                "\t\"apps\": %s\n"
                                "}\n",
                                row->number,
                                bar->adid,
                                row->apps_json        );
      bar_manager_handle_space_windows_change(&g_bar_manager, payload);
    }
  }
}
