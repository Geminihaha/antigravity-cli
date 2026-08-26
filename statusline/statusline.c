#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <signal.h>
#include <unistd.h>

#define R  "\033[0m"
#define B  "\033[1m"
#define D  "\033[2m"
#define I  "\033[3m"

#define FG_GRAY           "\033[90m"
#define FG_BRIGHT_RED     "\033[91m"
#define FG_BRIGHT_GREEN   "\033[92m"
#define FG_BRIGHT_YELLOW  "\033[93m"
#define FG_BRIGHT_BLUE    "\033[94m"
#define FG_BRIGHT_MAGENTA "\033[95m"
#define FG_BRIGHT_CYAN    "\033[96m"
#define FG_BRIGHT_WHITE   "\033[97m"
#define NUM_COLOR         FG_BRIGHT_WHITE B

// Minimal, ultra-fast JSON field extractor
static void get_json_str(const char *json, const char *key, char *out, size_t maxlen, const char *dflt) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) {
        snprintf(out, maxlen, "%s", dflt);
        return;
    }
    p += strlen(pattern);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (*p == '\"') {
        p++;
        size_t idx = 0;
        while (*p && *p != '\"' && idx < maxlen - 1) {
            if (*p == '\\' && *(p+1)) p++; // skip escape
            out[idx++] = *p++;
        }
        out[idx] = '\0';
    } else {
        snprintf(out, maxlen, "%s", dflt);
    }
}

static double get_json_double(const char *json, const char *key, double dflt) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return dflt;
    p += strlen(pattern);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    double val = dflt;
    if (sscanf(p, "%lf", &val) == 1) return val;
    return dflt;
}

static int get_json_int(const char *json, const char *key, int dflt) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return dflt;
    p += strlen(pattern);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    int val = dflt;
    if (sscanf(p, "%d", &val) == 1) return val;
    return dflt;
}

static bool get_json_bool(const char *json, const char *key, bool dflt) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return dflt;
    p += strlen(pattern);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (strncmp(p, "true", 4) == 0) return true;
    if (strncmp(p, "false", 5) == 0) return false;
    return dflt;
}

static int get_json_array_len(const char *json, const char *key) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (*p != '[') return 0;
    p++;
    while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    if (*p == ']') return 0;
    int count = 1;
    int depth = 0;
    while (*p && (*p != ']' || depth > 0)) {
        if (*p == '{' || *p == '[') depth++;
        else if (*p == '}' || *p == ']') depth--;
        else if (*p == ',' && depth == 0) count++;
        p++;
    }
    return count;
}

void sig_handler(int sig) {
    (void)sig;
    _exit(0);
}

int main(void) {
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGHUP, sig_handler);

    static char buf[65536];
    buf[0] = '\0';

    if (!isatty(STDIN_FILENO)) {
        // Read 1 line from stdin
        if (!fgets(buf, sizeof(buf), stdin)) {
            buf[0] = '\0';
        }
    }

    char state[64] = "idle";
    get_json_str(buf, "agent_state", state, sizeof(state), "idle");

    double used_pct = 0.0;
    const char *ctx_p = strstr(buf, "\"context_window\"");
    if (ctx_p) {
        used_pct = get_json_double(ctx_p, "used_percentage", 0.0);
    }

    char vcs_branch[128] = "";
    bool vcs_dirty = false;
    const char *vcs_p = strstr(buf, "\"vcs\"");
    if (vcs_p) {
        get_json_str(vcs_p, "branch", vcs_branch, sizeof(vcs_branch), "");
        vcs_dirty = get_json_bool(vcs_p, "dirty", false);
    }

    bool sandbox = false;
    const char *sb_p = strstr(buf, "\"sandbox\"");
    if (sb_p) {
        sandbox = get_json_bool(sb_p, "enabled", false);
    }

    int artifacts = get_json_int(buf, "artifact_count", 0);
    int subagents = get_json_array_len(buf, "subagents");
    int tasks = get_json_int(buf, "task_count", 0);

    char model[128] = "";
    const char *model_p = strstr(buf, "\"model\"");
    if (model_p) {
        get_json_str(model_p, "display_name", model, sizeof(model), "");
    }

    char cwd[512] = "";
    get_json_str(buf, "cwd", cwd, sizeof(cwd), "");

    int cols = get_json_int(buf, "terminal_width", 80);
    if (cols <= 0) cols = 80;

    // State formatting
    char s[128];
    if (strcmp(state, "idle") == 0) {
        snprintf(s, sizeof(s), "%s%s● READY%s", FG_BRIGHT_GREEN, B, R);
    } else if (strcmp(state, "thinking") == 0) {
        snprintf(s, sizeof(s), "%s%s◆ THINKING%s", FG_BRIGHT_YELLOW, B, R);
    } else if (strcmp(state, "working") == 0) {
        snprintf(s, sizeof(s), "%s%s⚙ WORKING%s", FG_BRIGHT_CYAN, B, R);
    } else if (strcmp(state, "tool_use") == 0) {
        snprintf(s, sizeof(s), "%s%s🔧 TOOL%s", FG_BRIGHT_MAGENTA, B, R);
    } else {
        char upper[64];
        size_t slen = strlen(state);
        if (slen >= sizeof(upper)) slen = sizeof(upper) - 1;
        for (size_t i = 0; i < slen; i++) {
            upper[i] = (state[i] >= 'a' && state[i] <= 'z') ? (state[i] - 32) : state[i];
        }
        upper[slen] = '\0';
        snprintf(s, sizeof(s), "%s%s⏳ %s%s", FG_BRIGHT_WHITE, B, upper, R);
    }

    // VCS formatting
    char v[256] = "";
    if (vcs_branch[0]) {
        if (vcs_dirty) {
            snprintf(v, sizeof(v), "%s ╱ %s%s%s*%s", FG_GRAY, FG_BRIGHT_RED, vcs_branch, FG_BRIGHT_YELLOW, R);
        } else {
            snprintf(v, sizeof(v), "%s ╱ %s%s%s", FG_GRAY, FG_BRIGHT_BLUE, vcs_branch, R);
        }
    }

    // Model formatting
    char m[256] = "";
    if (model[0]) {
        snprintf(m, sizeof(m), "%s ╱ %s%s%s%s", FG_GRAY, FG_BRIGHT_MAGENTA, I, model, R);
    }

    // CWD formatting
    char dir_fmt[600] = "";
    if (cwd[0]) {
        const char *home_dir = "/data/data/com.termux/files/home";
        char cwd_short[512];
        if (strncmp(cwd, home_dir, strlen(home_dir)) == 0) {
            snprintf(cwd_short, sizeof(cwd_short), "~%s", cwd + strlen(home_dir));
        } else {
            snprintf(cwd_short, sizeof(cwd_short), "%s", cwd);
        }
        snprintf(dir_fmt, sizeof(dir_fmt), "%s ╱ %s📂 %s%s", FG_GRAY, FG_BRIGHT_CYAN, cwd_short, R);
    }

    // Sandbox badge
    char sb[128];
    if (sandbox) {
        snprintf(sb, sizeof(sb), "%ssandbox %s%sON%s", FG_GRAY, FG_BRIGHT_GREEN, B, R);
    } else {
        snprintf(sb, sizeof(sb), "%ssandbox off%s", FG_GRAY, R);
    }

    // Context bar (15 segments)
    int pct_int = (int)used_pct;
    int bar_len = 15;
    int filled = (pct_int * bar_len) / 100;
    int remainder = (pct_int * bar_len) % 100;

    const char *bar_color = FG_BRIGHT_WHITE;
    if (pct_int >= 90) bar_color = FG_BRIGHT_RED;
    else if (pct_int >= 60) bar_color = FG_BRIGHT_YELLOW;

    char bar[128] = "";
    for (int i = 0; i < bar_len; i++) {
        if (i < filled) {
            strcat(bar, "█");
        } else if (i == filled) {
            if (remainder >= 75) strcat(bar, "▓");
            else if (remainder >= 50) strcat(bar, "▒");
            else if (remainder >= 25) strcat(bar, "░");
            else strcat(bar, "·");
        } else {
            strcat(bar, "·");
        }
    }

    char ctx[256];
    snprintf(ctx, sizeof(ctx), "%sctx %s%s %s%.1f%%%s", FG_GRAY, bar_color, bar, NUM_COLOR, used_pct, R);

    char art_fmt[128], sub_fmt[128], bg_fmt[128];
    snprintf(art_fmt, sizeof(art_fmt), "%sartifacts %s%d%s", FG_GRAY, NUM_COLOR, artifacts, R);
    snprintf(sub_fmt, sizeof(sub_fmt), "%ssubagents %s%d%s", FG_GRAY, NUM_COLOR, subagents, R);
    snprintf(bg_fmt, sizeof(bg_fmt), "%stasks %s%d%s", FG_GRAY, NUM_COLOR, tasks, R);

    const char *dot = FG_GRAY " · " R;

    char line1[1024];
    snprintf(line1, sizeof(line1), "%s%s%s%s", s, m, dir_fmt, v);

    char line2[1024];
    snprintf(line2, sizeof(line2), " %s%s%s%s%s%s%s%s%s", ctx, dot, art_fmt, dot, sub_fmt, dot, bg_fmt, dot, sb);

    if (cols >= 120) {
        printf("%s%s  │  %s%s\n", line1, FG_GRAY, R, line2);
    } else if (cols >= 80) {
        printf("%s╭─%s %s\n", FG_GRAY, R, line1);
        printf("%s╰─%s%s\n", FG_GRAY, R, line2);
    } else {
        printf("%s%s\n", s, m);
        printf("%s%s%s\n", ctx, dot, bg_fmt);
    }

    fflush(stdout);
    return 0;
}
