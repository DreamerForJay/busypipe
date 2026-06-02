/*
 * tools/gen_log.c — BusyPipe 測試用紀錄檔生成器
 *
 * 此工具不納入主專案建置流程，亦不整合進 BusyBox。
 * 生成的紀錄檔輸出至 samples/ 目錄（可用 --output 指定路徑）。
 *
 * 建置：make -C tools
 * 執行：./tools/build/gen_log --help
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>

/* ── 常數定義 ─────────────────────────────────────────────────────────────── */

#define MAX_IP_POOL   256
/* 24 bytes：保留 compiler 對 rand() 傳回值估算的最壞情況 */
#define IP_BUF_SIZE   24

/* ── 型別定義 ─────────────────────────────────────────────────────────────── */

typedef enum {
    FMT_NGINX,
    FMT_APACHE,
    FMT_AUTH,
    FMT_CUSTOM
} log_format_t;

typedef struct {
    log_format_t format;
    char         output[512];
    long         count;
    unsigned int seed;
    bool         seed_set;
    bool         append;
    bool         quiet;

    /* nginx / apache 專用 */
    int error_rate;        /* 4xx/5xx 比例 0-100，預設 20   */
    int path_pool;         /* 唯一路徑數，預設 20            */
    int method_get;        /* GET 比例 0-100，預設 70        */
    int no_bytes_rate;     /* "-" bytes 比例（apache），預設 15 */

    /* auth 專用 */
    int fail_rate;         /* Failed 比例 0-100，預設 40     */
    int user_pool;         /* 唯一用戶名數，預設 5           */

    /* 共用 */
    int  ip_pool;          /* 唯一 IP 數，預設 10            */
    long time_start;       /* 起始 epoch，預設當前時間       */
    int  time_step;        /* 每筆間隔秒（0=隨機 1-30），預設 0 */
} config_t;

/* ── 靜態資料池 ───────────────────────────────────────────────────────────── */

static const char *PATHS[] = {
    "/", "/index.html", "/about.html", "/contact.html",
    "/api/users", "/api/login", "/api/data", "/api/products",
    "/api/orders", "/api/search", "/api/health", "/api/metrics",
    "/admin", "/admin/login", "/admin/dashboard",
    "/dashboard", "/search", "/products", "/cart", "/checkout",
    "/login", "/logout", "/register", "/profile", "/settings",
    "/static/main.css", "/static/app.js", "/favicon.ico",
    "/robots.txt", "/images/logo.png", "/sitemap.xml",
    "/report.csv", "/export/data", "/upload", "/docs/api",
    "/feeds/rss", "/item/5", "/user/profile", "/session/42",
};
#define N_PATHS ((int)(sizeof(PATHS) / sizeof(PATHS[0])))

static const char *USERS[] = {
    "root", "admin", "user", "test", "ubuntu",
    "debian", "oracle", "postgres", "mysql", "ftp",
    "guest", "pi", "deploy", "www-data", "backup",
    "jenkins", "nagios", "docker", "vagrant", "ansible",
};
#define N_USERS ((int)(sizeof(USERS) / sizeof(USERS[0])))

static const char *HOSTS[] = {
    "router", "server", "gateway", "proxy", "node1",
    "db01", "web01", "bastion", "edge", "hub",
};
#define N_HOSTS ((int)(sizeof(HOSTS) / sizeof(HOSTS[0])))

static const char *ACTIONS[] = {
    "user_login", "user_logout", "db_query",
    "api_request", "file_upload", "cache_hit",
    "cache_miss", "auth_check",
};
#define N_ACTIONS ((int)(sizeof(ACTIONS) / sizeof(ACTIONS[0])))

static const char *LEVELS[] = { "INFO", "WARN", "ERROR", "DEBUG" };

static const char *UA[] = {
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    "curl/7.68.0",
    "python-requests/2.27.1",
    "Go-http-client/1.1",
    "Wget/1.21.1",
};
#define N_UA ((int)(sizeof(UA) / sizeof(UA[0])))

static const char *REFERRERS[] = {
    "-", "-", "-",
    "http://example.com/",
    "https://google.com/",
    "https://github.com/",
};
#define N_REFERRERS ((int)(sizeof(REFERRERS) / sizeof(REFERRERS[0])))

static const char *MONTHS[] = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/* IP 池：srand 後 build_ip_pool() 一次性填充 */
static char g_ip_pool[MAX_IP_POOL][IP_BUF_SIZE];

/* ── 亂數輔助 ─────────────────────────────────────────────────────────────── */

static int rand_range(int lo, int hi) {
    return lo + rand() % (hi - lo + 1);
}

static bool rand_pct(int pct) {
    return (rand() % 100) < pct;
}

/* 從長度為 pool_size 的池中取索引 */
static int rand_from(int pool_size) {
    return rand() % pool_size;
}

/* ── IP 池管理 ────────────────────────────────────────────────────────────── */

static void build_ip_pool(int size) {
    int i;
    for (i = 0; i < size; i++) {
        snprintf(g_ip_pool[i], IP_BUF_SIZE, "%d.%d.%d.%d",
                 rand_range(1, 223),
                 rand_range(0, 255),
                 rand_range(0, 255),
                 rand_range(1, 254));
    }
}

/* ── 時間格式化 ───────────────────────────────────────────────────────────── */

/* nginx / apache：[30/Apr/2026:10:00:00 +0800] */
static void fmt_combined(char *buf, time_t t) {
    struct tm *tm = localtime(&t);
    sprintf(buf, "%02d/%s/%04d:%02d:%02d:%02d +0800",
            tm->tm_mday, MONTHS[tm->tm_mon],
            1900 + tm->tm_year,
            tm->tm_hour, tm->tm_min, tm->tm_sec);
}

/* auth：Apr 30 08:10:10（單位數日期補空格） */
static void fmt_auth(char *buf, time_t t) {
    struct tm *tm = localtime(&t);
    sprintf(buf, "%s %2d %02d:%02d:%02d",
            MONTHS[tm->tm_mon], tm->tm_mday,
            tm->tm_hour, tm->tm_min, tm->tm_sec);
}

/* custom：2026-04-30T08:00:00 */
static void fmt_iso(char *buf, time_t t) {
    struct tm *tm = localtime(&t);
    sprintf(buf, "%04d-%02d-%02dT%02d:%02d:%02d",
            1900 + tm->tm_year, tm->tm_mon + 1, tm->tm_mday,
            tm->tm_hour, tm->tm_min, tm->tm_sec);
}

/* ── HTTP 欄位選取 ────────────────────────────────────────────────────────── */

static const char *pick_method(int method_get) {
    if (rand_pct(method_get)) return "GET";
    /* 剩餘均分 POST / PUT / DELETE / HEAD */
    switch (rand_range(0, 3)) {
    case 0:  return "POST";
    case 1:  return "PUT";
    case 2:  return "DELETE";
    default: return "HEAD";
    }
}

static int pick_status(int error_rate, const char *method) {
    static const int S4XX[] = { 400, 401, 403, 404, 429 };
    static const int S5XX[] = { 500, 502, 503 };
    static const int S2XX[] = { 200, 200, 200, 201, 204 };

    if (strcmp(method, "HEAD") == 0)
        return 200;

    if (rand_pct(error_rate)) {
        if (rand_pct(75))
            return S4XX[rand_range(0, 4)];
        return S5XX[rand_range(0, 2)];
    }
    if (rand_pct(15))
        return rand_pct(50) ? 301 : 302;
    return S2XX[rand_range(0, 4)];
}

/* ── 各格式寫入 ───────────────────────────────────────────────────────────── */

static void write_nginx(FILE *f, const config_t *cfg, time_t t) {
    const char *method = pick_method(cfg->method_get);
    const char *path   = PATHS[rand_from(cfg->path_pool)];
    int         status = pick_status(cfg->error_rate, method);
    char        ts[80];
    const char *ip     = g_ip_pool[rand_from(cfg->ip_pool)];

    fmt_combined(ts, t);
    /* nginx regex 要求 bytes 為 [0-9]+，一律輸出數字 */
    fprintf(f, "%s - - [%s] \"%s %s HTTP/1.1\" %d %d \"%s\" \"%s\"\n",
            ip, ts, method, path, status,
            rand_range(64, 65536),
            REFERRERS[rand_from(N_REFERRERS)],
            UA[rand_from(N_UA)]);
}

static void write_apache(FILE *f, const config_t *cfg, time_t t) {
    const char *method = pick_method(cfg->method_get);
    const char *path   = PATHS[rand_from(cfg->path_pool)];
    int         status = pick_status(cfg->error_rate, method);
    char        ts[80];
    const char *ip     = g_ip_pool[rand_from(cfg->ip_pool)];
    /* HEAD 請求、3xx 轉址、以及 no_bytes_rate 機率時，bytes 輸出 "-" */
    bool no_bytes = (strcmp(method, "HEAD") == 0)
                 || (status / 100 == 3)
                 || rand_pct(cfg->no_bytes_rate);

    fmt_combined(ts, t);
    if (no_bytes)
        fprintf(f, "%s - - [%s] \"%s %s HTTP/1.1\" %d -\n",
                ip, ts, method, path, status);
    else
        fprintf(f, "%s - - [%s] \"%s %s HTTP/1.1\" %d %d\n",
                ip, ts, method, path, status, rand_range(64, 65536));
}

static void write_auth(FILE *f, const config_t *cfg, time_t t) {
    const char *result = rand_pct(cfg->fail_rate) ? "Failed" : "Accepted";
    const char *user   = USERS[rand_from(cfg->user_pool)];
    const char *src_ip = g_ip_pool[rand_from(cfg->ip_pool)];
    const char *host   = HOSTS[rand_from(N_HOSTS)];
    char        ts[80];

    fmt_auth(ts, t);
    fprintf(f, "%s %s sshd[%d]: %s password for %s from %s port %d ssh2\n",
            ts, host, rand_range(1000, 99999),
            result, user, src_ip, rand_range(20000, 65535));
}

static void write_custom(FILE *f, const config_t *cfg, time_t t) {
    const char *level  = LEVELS[rand_from(4)];
    const char *action = ACTIONS[rand_from(N_ACTIONS)];
    const char *ip     = g_ip_pool[rand_from(cfg->ip_pool)];
    const char *result;
    int         duration;
    char        ts[80];

    if      (strcmp(level, "ERROR") == 0) { result = "failed";  duration = 0; }
    else if (strcmp(level, "WARN")  == 0) { result = rand_pct(50) ? "slow" : "timeout";
                                            duration = rand_range(1000, 9999); }
    else                                  { result = "success"; duration = rand_range(1, 500); }

    fmt_iso(ts, t);
    /* 格式與 samples/custom.log 一致，符合自訂 regex：
     * ^([^ ]+) +([A-Z]+) +([^ ]+) +([^ ]+) +([^ ]+) +([0-9]+) */
    fprintf(f, "%s %-5s %-15s %-15s %-7s %d\n",
            ts, level, ip, action, result, duration);
}

/* ── 說明文字 ─────────────────────────────────────────────────────────────── */

static void show_usage(FILE *out, const char *prog) {
    fprintf(out,
        "用法：%s [選項]\n"
        "\n"
        "格式選項：\n"
        "  --format nginx|apache|auth|custom\n"
        "                      紀錄格式（預設：nginx）\n"
        "\n"
        "輸出選項：\n"
        "  --output <路徑>     輸出檔（預設：samples/<format>_gen.log）\n"
        "  --count <n>         生成筆數（預設：100）\n"
        "  --append            附加至現有檔案（預設：覆寫）\n"
        "  --quiet, -q         不輸出完成訊息\n"
        "\n"
        "隨機性控制：\n"
        "  --seed <n>          亂數種子（預設：依時間；0 = 固定種子 42）\n"
        "\n"
        "nginx / apache 格式專用：\n"
        "  --error-rate <0-100>      4xx/5xx 比例（預設：20）\n"
        "  --path-pool <1-%d>       唯一路徑數（預設：20）\n"
        "  --method-get <0-100>      GET 比例（預設：70；其餘均分 POST/PUT/DELETE/HEAD）\n"
        "  --no-bytes-rate <0-100>   bytes 欄位為 \"-\" 的比例，僅 apache（預設：15）\n"
        "                            備註：HEAD 請求與 3xx 轉址永遠輸出 \"-\"，\n"
        "                            此參數為額外追加比例\n"
        "\n"
        "auth 格式專用：\n"
        "  --fail-rate <0-100>   Failed password 比例（預設：40）\n"
        "  --user-pool <1-%d>   唯一用戶名數（預設：5）\n"
        "\n"
        "共用選項：\n"
        "  --ip-pool <1-%d>    唯一來源 IP 數（預設：10）\n"
        "  --time-start <epoch> 起始 Unix 時間戳（預設：當前時間）\n"
        "  --time-step <秒>     每筆時間間隔（0 = 隨機 1-30 秒，預設：0）\n"
        "\n"
        "其他：\n"
        "  --help, -h          顯示此說明\n"
        "\n"
        "範例：\n"
        "  %s --format nginx  --count 1000 --error-rate 30 --ip-pool 50\n"
        "  %s --format apache --count 500  --no-bytes-rate 25 --path-pool 5\n"
        "  %s --format auth   --count 300  --fail-rate 70  --user-pool 3\n"
        "  %s --format custom --count 200  --seed 42\n"
        "  %s --format nginx  --output samples/my_test.log --count 50 --seed 0\n"
        "  %s --format nginx  --count 100 --append\n",
        prog, N_PATHS, N_USERS, MAX_IP_POOL,
        prog, prog, prog, prog, prog, prog);
}

/* ── 引數解析 ─────────────────────────────────────────────────────────────── */

static void die(const char *msg) {
    fprintf(stderr, "錯誤：%s\n", msg);
    exit(1);
}

static int parse_int_arg(const char *name, const char *val) {
    char *end;
    long v = strtol(val, &end, 10);
    if (*end != '\0') {
        fprintf(stderr, "錯誤：%s 需要整數，got \"%s\"\n", name, val);
        exit(1);
    }
    return (int)v;
}

static void check_range(const char *name, int v, int lo, int hi) {
    if (v < lo || v > hi) {
        fprintf(stderr, "錯誤：%s 超出範圍 %d-%d（got %d）\n", name, lo, hi, v);
        exit(1);
    }
}

static void parse_args(int argc, char **argv, config_t *cfg) {
    int i;

    /* 預設值 */
    cfg->format        = FMT_NGINX;
    cfg->output[0]     = '\0';
    cfg->count         = 100;
    cfg->seed          = 0;
    cfg->seed_set      = false;
    cfg->append        = false;
    cfg->quiet         = false;
    cfg->error_rate    = 20;
    cfg->path_pool     = 20;
    cfg->method_get    = 70;
    cfg->no_bytes_rate = 15;
    cfg->fail_rate     = 40;
    cfg->user_pool     = 5;
    cfg->ip_pool       = 10;
    cfg->time_start    = (long)time(NULL);
    cfg->time_step     = 0;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            show_usage(stdout, argv[0]);
            exit(0);

        } else if (strcmp(argv[i], "--format") == 0 && i + 1 < argc) {
            const char *f = argv[++i];
            if      (strcmp(f, "nginx")  == 0) cfg->format = FMT_NGINX;
            else if (strcmp(f, "apache") == 0) cfg->format = FMT_APACHE;
            else if (strcmp(f, "auth")   == 0) cfg->format = FMT_AUTH;
            else if (strcmp(f, "custom") == 0) cfg->format = FMT_CUSTOM;
            else {
                fprintf(stderr, "錯誤：未知格式 \"%s\"（支援：nginx, apache, auth, custom）\n", f);
                exit(1);
            }

        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            strncpy(cfg->output, argv[++i], sizeof(cfg->output) - 1);
            cfg->output[sizeof(cfg->output) - 1] = '\0';

        } else if (strcmp(argv[i], "--count") == 0 && i + 1 < argc) {
            cfg->count = atol(argv[++i]);
            if (cfg->count <= 0) die("--count 必須大於 0");

        } else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
            cfg->seed     = (unsigned int)parse_int_arg("--seed", argv[++i]);
            cfg->seed_set = true;

        } else if (strcmp(argv[i], "--append") == 0) {
            cfg->append = true;

        } else if (strcmp(argv[i], "--quiet") == 0 || strcmp(argv[i], "-q") == 0) {
            cfg->quiet = true;

        } else if (strcmp(argv[i], "--error-rate") == 0 && i + 1 < argc) {
            cfg->error_rate = parse_int_arg("--error-rate", argv[++i]);
            check_range("--error-rate",    cfg->error_rate,    0, 100);

        } else if (strcmp(argv[i], "--path-pool") == 0 && i + 1 < argc) {
            cfg->path_pool = parse_int_arg("--path-pool", argv[++i]);
            check_range("--path-pool",     cfg->path_pool,     1, N_PATHS);

        } else if (strcmp(argv[i], "--method-get") == 0 && i + 1 < argc) {
            cfg->method_get = parse_int_arg("--method-get", argv[++i]);
            check_range("--method-get",    cfg->method_get,    0, 100);

        } else if (strcmp(argv[i], "--no-bytes-rate") == 0 && i + 1 < argc) {
            cfg->no_bytes_rate = parse_int_arg("--no-bytes-rate", argv[++i]);
            check_range("--no-bytes-rate", cfg->no_bytes_rate, 0, 100);

        } else if (strcmp(argv[i], "--fail-rate") == 0 && i + 1 < argc) {
            cfg->fail_rate = parse_int_arg("--fail-rate", argv[++i]);
            check_range("--fail-rate",     cfg->fail_rate,     0, 100);

        } else if (strcmp(argv[i], "--user-pool") == 0 && i + 1 < argc) {
            cfg->user_pool = parse_int_arg("--user-pool", argv[++i]);
            check_range("--user-pool",     cfg->user_pool,     1, N_USERS);

        } else if (strcmp(argv[i], "--ip-pool") == 0 && i + 1 < argc) {
            cfg->ip_pool = parse_int_arg("--ip-pool", argv[++i]);
            check_range("--ip-pool",       cfg->ip_pool,       1, MAX_IP_POOL);

        } else if (strcmp(argv[i], "--time-start") == 0 && i + 1 < argc) {
            cfg->time_start = atol(argv[++i]);

        } else if (strcmp(argv[i], "--time-step") == 0 && i + 1 < argc) {
            cfg->time_step = parse_int_arg("--time-step", argv[++i]);
            if (cfg->time_step < 0) die("--time-step 不可為負數");

        } else {
            fprintf(stderr, "錯誤：未知選項 \"%s\"\n\n", argv[i]);
            show_usage(stderr, argv[0]);
            exit(1);
        }
    }

    /* 設定預設輸出路徑 */
    if (cfg->output[0] == '\0') {
        static const char *names[] = { "nginx", "apache", "auth", "custom" };
        snprintf(cfg->output, sizeof(cfg->output),
                 "samples/%s_gen.log", names[cfg->format]);
    }
}

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    config_t cfg;
    FILE    *f;
    long     i;
    time_t   cur;
    static const char *fmt_names[] = { "nginx", "apache", "auth", "custom" };

    parse_args(argc, argv, &cfg);

    /* 初始化亂數種子 */
    if (cfg.seed_set && cfg.seed == 0)
        srand(42);
    else if (cfg.seed_set)
        srand(cfg.seed);
    else
        srand((unsigned int)time(NULL));

    /* 在 srand 後立即建立 IP 池，確保可重現性 */
    build_ip_pool(cfg.ip_pool);

    f = fopen(cfg.output, cfg.append ? "a" : "w");
    if (!f) {
        perror(cfg.output);
        return 1;
    }

    cur = (time_t)cfg.time_start;

    for (i = 0; i < cfg.count; i++) {
        switch (cfg.format) {
        case FMT_NGINX:  write_nginx(f,  &cfg, cur); break;
        case FMT_APACHE: write_apache(f, &cfg, cur); break;
        case FMT_AUTH:   write_auth(f,   &cfg, cur); break;
        case FMT_CUSTOM: write_custom(f, &cfg, cur); break;
        }
        cur += (cfg.time_step == 0) ? rand_range(1, 30) : cfg.time_step;
    }

    fclose(f);

    if (!cfg.quiet) {
        fprintf(stderr, "生成完成：%s（%ld 筆，格式：%s，%s）\n",
                cfg.output, cfg.count, fmt_names[cfg.format],
                cfg.append ? "附加" : "覆寫");
    }
    return 0;
}
