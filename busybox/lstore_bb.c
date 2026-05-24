/* lstore_bb.c — BusyBox applet adaptation of lstore
 *
 * To integrate: cp lstore_bb.c <busybox>/miscutils/lstore.c
 * Then patch applets.h / Config.in / miscutils/Kbuild  (see README-integration.md)
 */

/*
//usage:#define lstore_trivial_usage \
//usage:    "--db PATH --put --key-field FIELD [--ttl SEC] [--stats] |\n" \
//usage:    "           --get KEY | --delete KEY | --list | --cleanup | --count"
//usage:#define lstore_full_usage "\n\n" \
//usage:    "File-backed key-value store with TTL support.\n" \
//usage:    "\n" \
//usage:    "Storage format:  key<TAB>expires_epoch<TAB>raw_csv_row\n" \
//usage:    "\n" \
//usage:    "Options:\n" \
//usage:    "  --db PATH         Database file path (TSV)\n" \
//usage:    "  --put             Read CSV from stdin, append to db\n" \
//usage:    "    --key-field F   CSV column used as key\n" \
//usage:    "    --ttl SEC       Expiry in seconds (0 = never)\n" \
//usage:    "  --get KEY         Print most-recent non-expired record\n" \
//usage:    "  --delete KEY      Remove all records with KEY\n" \
//usage:    "  --list            Print all valid records\n" \
//usage:    "  --cleanup         Rewrite db, remove expired records\n" \
//usage:    "  --count           Print number of valid records\n" \
//usage:    "  --stats           Print operation stats to stderr\n"
*/

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "busypipe.h"

typedef enum {
    M_NONE,M_PUT,M_GET,M_DEL,M_LIST,M_CLEANUP,M_COUNT
} mode_t;

static long now_sec(void) { return (long)time(NULL); }
static bool expired(long e) { return e!=0 && e<=now_sec(); }

static bool parse_record(char *line, char **key, long *exp, char **val) {
    bp_trim_newline(line);
    *key = strtok(line,"\t");
    char *es = strtok(NULL,"\t");
    *val = strtok(NULL,"");
    if(!*key||!es||!*val) return false;
    *exp = atol(es);
    return true;
}

/* ── BusyBox entry point ─────────────────────────────────────────── */
/* int lstore_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE; */
int main(int argc, char **argv) {
    mode_t mode=M_NONE;
    const char *db=NULL, *key_arg=NULL;
    char key_field[128]={0};
    long ttl=0;
    bool stats=false;
    int i;

    for (i=1;i<argc;i++) {
        if      (!strcmp(argv[i],"--db")       && i+1<argc) db=argv[++i];
        else if (!strcmp(argv[i],"--put"))       mode=M_PUT;
        else if (!strcmp(argv[i],"--get")      && i+1<argc){mode=M_GET;  key_arg=argv[++i];}
        else if (!strcmp(argv[i],"--delete")   && i+1<argc){mode=M_DEL;  key_arg=argv[++i];}
        else if (!strcmp(argv[i],"--list"))      mode=M_LIST;
        else if (!strcmp(argv[i],"--cleanup"))   mode=M_CLEANUP;
        else if (!strcmp(argv[i],"--count"))     mode=M_COUNT;
        else if (!strcmp(argv[i],"--key-field") && i+1<argc)
            strncpy(key_field,argv[++i],127);
        else if (!strcmp(argv[i],"--ttl")      && i+1<argc) ttl=atol(argv[++i]);
        else if (!strcmp(argv[i],"--stats"))     stats=true;
        else if (!strcmp(argv[i],"--help")||!strcmp(argv[i],"-h")) {
            fprintf(stderr,
                "用法：lstore --db PATH [--put --key-field F [--ttl N] | "
                "--get K | --delete K | --list | --cleanup | --count]\n");
            return 0;
        } else {
            fprintf(stderr,"lstore: unknown option '%s'\n",argv[i]); return 1;
        }
    }

    if (!db||mode==M_NONE) {
        fprintf(stderr,"lstore: --db and a mode are required\n"); return 1;
    }
    if (mode==M_PUT && !key_field[0]) {
        fprintf(stderr,"lstore: --put requires --key-field\n"); return 1;
    }

    /* ── PUT ── */
    if (mode==M_PUT) {
        char hbuf[BP_MAX_LINE_LEN];
        if (!fgets(hbuf,sizeof(hbuf),stdin)) return 0;
        bp_trim_newline(hbuf);
        bp_list_t hdr; memset(&hdr,0,sizeof(hdr));
        if (!bp_split(hbuf,',',&hdr)){fprintf(stderr,"lstore: bad header\n");return 1;}
        int kidx=bp_find_field(&hdr,key_field);
        if (kidx<0){fprintf(stderr,"lstore: key-field '%s' not found\n",key_field);return 1;}
        long exp_at = ttl>0 ? now_sec()+ttl : 0;
        FILE *db_fp=fopen(db,"a");
        if(!db_fp){fprintf(stderr,"lstore: cannot open '%s'\n",db);return 1;}
        char line[BP_MAX_LINE_LEN];
        unsigned long written=0;
        while (fgets(line,sizeof(line),stdin)) {
            char buf[BP_MAX_LINE_LEN]; bp_trim_newline(line);
            if(!line[0]) continue;
            strncpy(buf,line,sizeof(buf)-1);
            bp_list_t row; memset(&row,0,sizeof(row));
            if(!bp_split(buf,',',&row)||row.count!=hdr.count) continue;
            fprintf(db_fp,"%s\t%ld\t%s\n",row.items[kidx],exp_at,line);
            written++;
        }
        fflush(db_fp); fclose(db_fp);
        if (stats) fprintf(stderr,"put: written=%lu\n",written);
        return 0;
    }

    /* ── GET / LIST / DELETE / CLEANUP / COUNT ── */
    FILE *in=fopen(db,"r");
    if (!in) {
        if (errno==ENOENT) return 0;
        fprintf(stderr,"lstore: cannot open '%s'\n",db); return 1;
    }

    char tmp_path[BP_MAX_LINE_LEN];
    snprintf(tmp_path,sizeof(tmp_path),"%s.tmp",db);
    bool rewrite=(mode==M_DEL||mode==M_CLEANUP);
    FILE *out=NULL;
    if (rewrite) {
        out=fopen(tmp_path,"w");
        if(!out){fclose(in);fprintf(stderr,"lstore: cannot write tmp\n");return 1;}
    }

    char line[BP_MAX_LINE_LEN];
    char latest[BP_MAX_LINE_LEN]={0};
    bool found=false;
    unsigned long kept=0,removed=0,total=0;

    while (fgets(line,sizeof(line),in)) {
        char cp[BP_MAX_LINE_LEN];
        strncpy(cp,line,sizeof(cp)-1);
        char *k,*v; long exp;
        total++;
        if (!parse_record(cp,&k,&exp,&v)) continue;
        if (expired(exp)){removed++;continue;}
        bool match=(key_arg&&!strcmp(k,key_arg));
        if (mode==M_GET&&match){strncpy(latest,v,sizeof(latest)-1);found=true;}
        else if (mode==M_LIST){printf("%s\t%s\n",k,v);kept++;}
        else if (mode==M_COUNT) kept++;
        if (rewrite) {
            if (mode==M_DEL&&match){removed++;continue;}
            fprintf(out,"%s\t%ld\t%s\n",k,exp,v); kept++;
        }
    }
    fclose(in);
    if (mode==M_GET) {
        if (found) puts(latest);
        else fprintf(stderr,"lstore: key '%s' not found\n",key_arg?key_arg:"");
    }
    if (mode==M_COUNT) printf("%lu\n",kept);
    if (rewrite) {
        fclose(out);
        if (remove(db)!=0&&errno!=ENOENT){
            fprintf(stderr,"lstore: cannot remove old db\n"); return 1;
        }
        if (rename(tmp_path,db)!=0) {
            /* cross-device fallback */
            FILE *s=fopen(tmp_path,"rb"), *d=fopen(db,"wb");
            char buf[4096]; size_t n;
            if (s&&d) { while((n=fread(buf,1,4096,s))>0) fwrite(buf,1,n,d); }
            if (s) fclose(s);
            if (d) fclose(d);
            remove(tmp_path);
        }
    }
    if (stats)
        fprintf(stderr,"scan: total=%lu kept=%lu removed=%lu\n",total,kept,removed);
    return 0;
}
