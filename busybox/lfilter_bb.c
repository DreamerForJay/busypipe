/* lfilter_bb.c — lfilter 的 BusyBox applet 適配版
 *
 * 整合至 BusyBox 原始碼樹：
 *   cp lfilter_bb.c   <busybox>/miscutils/lfilter.c
 *   cp libpipe.c      <busybox>/libbb/busypipe_lib.c   （若尚未複製）
 *   cp libpipe.h      <busybox>/include/libpipe.h      （若尚未複製）
 *
 * 執行 scripts/gen_build_files.sh 後，下方指令自動生成對應 applets.h/Kbuild/Config.in。
 */
//applet:IF_LFILTER(APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP))
//kbuild:lib-$(CONFIG_LFILTER) += lfilter.o
//kbuild:CFLAGS_lfilter.o += -DBUSYBOX_BUILD
//config:config LFILTER
//config:	bool "lfilter"
//config:	default y
//config:	help
//config:	  CSV stream filter applet. Part of BusyPipe embedded ETL pipeline.
//config:	  Filters rows by condition, projects fields, outputs CSV or JSONL.

/*
//usage:#define lfilter_trivial_usage \
//usage:    "[--where expr] [--select f1,f2,...] [--contains f=sub] [--format csv|json]"
//usage:#define lfilter_full_usage "\n\n" \
//usage:    "Filter and project a CSV stream.\n" \
//usage:    "\n" \
//usage:    "Options:\n" \
//usage:    "  --where  \"field<op>value\"  Comparison filter (==!=><>=<=)\n" \
//usage:    "  --contains \"field=substr\"  Substring filter\n" \
//usage:    "  --select \"f1,f2,...\"        Field projection\n" \
//usage:    "  --format csv|json           Output format (default csv)\n"
*/

/* ── 獨立編譯時使用；BusyBox 整合時將以下替換為 #include "libbb.h" ── */
#include <stdlib.h>
#include <string.h>
#include "libpipe.h"

typedef enum { OP_NONE,OP_EQ,OP_NE,OP_GT,OP_GE,OP_LT,OP_LE } op_t;
typedef enum { FMT_CSV, FMT_JSON } fmt_t;

/* ── BusyBox 整合入口 ──────────────────────────────────────────── */
int lfilter_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
int lfilter_main(int argc, char **argv) {
    char where_buf[256]={0}, sel_buf[1024]={0}, cont_buf[256]={0};
    bool has_where=false, has_sel=false, has_cont=false;
    char where_f[128]={0}, where_v[128]={0};
    char cont_f[128]={0},  cont_v[128]={0};
    op_t  where_op = OP_NONE;
    fmt_t out_fmt  = FMT_CSV;
    bp_list_t sel_fields;
    memset(&sel_fields,0,sizeof(sel_fields));

    int i;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i],"--where") && i+1<argc) {
            strncpy(where_buf, argv[++i], sizeof(where_buf)-1);
            has_where = true;
        } else if (!strcmp(argv[i],"--select") && i+1<argc) {
            strncpy(sel_buf, argv[++i], sizeof(sel_buf)-1);
            has_sel = true;
        } else if (!strcmp(argv[i],"--contains") && i+1<argc) {
            strncpy(cont_buf, argv[++i], sizeof(cont_buf)-1);
            has_cont = true;
        } else if (!strcmp(argv[i],"--format") && i+1<argc) {
            ++i;
            if (!strcmp(argv[i],"json")) out_fmt = FMT_JSON;
            else if (!strcmp(argv[i],"csv")) out_fmt = FMT_CSV;
            else { fprintf(stderr,"lfilter: unknown format '%s'\n",argv[i]); return 1; }
        } else if (!strcmp(argv[i],"--help")||!strcmp(argv[i],"-h")) {
            fprintf(stderr,
                "用法：lfilter [--where expr] [--select f1,f2] "
                "[--contains f=sub] [--format csv|json]\n");
            return 0;
        } else {
            fprintf(stderr,"lfilter: unknown option '%s'\n",argv[i]); return 1;
        }
    }

    /* parse --where */
    if (has_where) {
        static const struct{const char*t;op_t op;}ops[]=
            {{">=",OP_GE},{"<=",OP_LE},{"==",OP_EQ},{"!=",OP_NE},{">",OP_GT},{"<",OP_LT}};
        size_t k;
        for (k=0;k<6;k++){
            char *p=strstr(where_buf,ops[k].t);
            if(p){
                size_t llen=(size_t)(p-where_buf);
                size_t rlen=strlen(p+strlen(ops[k].t));
                if(!llen||!rlen||llen>=128||rlen>=128){
                    fprintf(stderr,"lfilter: bad --where expr\n");return 1;}
                memcpy(where_f,where_buf,llen); where_f[llen]='\0';
                memcpy(where_v,p+strlen(ops[k].t),rlen); where_v[rlen]='\0';
                where_op=ops[k].op; break;
            }
        }
        if (where_op==OP_NONE){fprintf(stderr,"lfilter: bad --where\n");return 1;}
    }

    /* parse --contains */
    if (has_cont) {
        char *eq=strchr(cont_buf,'=');
        if(!eq||eq==cont_buf){fprintf(stderr,"lfilter: bad --contains\n");return 1;}
        size_t llen=(size_t)(eq-cont_buf);
        memcpy(cont_f,cont_buf,llen); cont_f[llen]='\0';
        strncpy(cont_v,eq+1,127);
    }

    /* parse --select */
    if (has_sel && !bp_split(sel_buf,',',&sel_fields)) {
        fprintf(stderr,"lfilter: too many --select fields\n"); return 1;
    }

    /* read header */
    char hbuf[BP_MAX_LINE_LEN];
    if (!fgets(hbuf,sizeof(hbuf),stdin)) return 0;
    bp_trim_newline(hbuf);
    bp_list_t header; memset(&header,0,sizeof(header));
    if (!bp_split(hbuf,',',&header)) {
        fprintf(stderr,"lfilter: bad CSV header\n"); return 1;
    }

    int where_idx=-1, cont_idx=-1;
    int sel_idx[BP_MAX_FIELDS]; memset(sel_idx,0,sizeof(sel_idx));

    if (has_where) {
        where_idx=bp_find_field(&header,where_f);
        if(where_idx<0){fprintf(stderr,"lfilter: field '%s' not found\n",where_f);return 1;}
    }
    if (has_cont) {
        cont_idx=bp_find_field(&header,cont_f);
        if(cont_idx<0){fprintf(stderr,"lfilter: field '%s' not found\n",cont_f);return 1;}
    }
    if (has_sel) {
        size_t s;
        for (s=0;s<sel_fields.count;s++){
            sel_idx[s]=bp_find_field(&header,sel_fields.items[s]);
            if(sel_idx[s]<0){
                fprintf(stderr,"lfilter: select field '%s' not found\n",sel_fields.items[s]);
                return 1;
            }
        }
    }

    /* print header */
    if (out_fmt==FMT_CSV) {
        if (has_sel) {
            bp_list_t out; out.count=sel_fields.count;
            size_t s;
            for(s=0;s<sel_fields.count;s++) out.items[s]=header.items[sel_idx[s]];
            bp_print_csv(stdout,&out);
        } else {
            bp_print_csv(stdout,&header);
        }
    }

    /* process rows */
    char line[BP_MAX_LINE_LEN];
    while (fgets(line,sizeof(line),stdin)) {
        char buf[BP_MAX_LINE_LEN];
        bp_list_t row;
        bp_trim_newline(line);
        if (!line[0]) continue;
        strncpy(buf,line,sizeof(buf)-1);
        buf[sizeof(buf)-1] = '\0';   /* explicit null-termination */
        if (!bp_split(buf,',',&row)||row.count!=header.count) continue;

        /* --where filter */
        if (has_where) {
            const char *lv=row.items[where_idx];
            const char *rv=where_v;
            int pass=0;
            if (bp_is_number(lv)&&bp_is_number(rv)) {
                double a=atof(lv),b=atof(rv);
                switch(where_op){
                    case OP_EQ: pass=(a==b); break; case OP_NE: pass=(a!=b); break;
                    case OP_GT: pass=(a>b);  break; case OP_GE: pass=(a>=b); break;
                    case OP_LT: pass=(a<b);  break; case OP_LE: pass=(a<=b); break;
                    default: break;
                }
            } else {
                int c=strcmp(lv,rv);
                switch(where_op){
                    case OP_EQ: pass=(c==0); break; case OP_NE: pass=(c!=0); break;
                    case OP_GT: pass=(c>0);  break; case OP_GE: pass=(c>=0); break;
                    case OP_LT: pass=(c<0);  break; case OP_LE: pass=(c<=0); break;
                    default: break;
                }
            }
            if (!pass) continue;
        }

        /* --contains filter */
        if (has_cont && !strstr(row.items[cont_idx],cont_v)) continue;

        /* emit */
        if (out_fmt==FMT_JSON) {
            size_t n=has_sel?sel_fields.count:header.count, j;
            putchar('{');
            for(j=0;j<n;j++){
                int col=has_sel?sel_idx[j]:(int)j;
                if(j) putchar(',');
                putchar('"');
                bp_json_escape(header.items[col]);
                printf("\":\"");
                bp_json_escape(row.items[col]);   /* was: raw %s, no escaping */
                putchar('"');
            }
            puts("}");
        } else if (has_sel) {
            bp_list_t out; out.count=sel_fields.count;
            size_t s;
            for(s=0;s<sel_fields.count;s++) out.items[s]=row.items[sel_idx[s]];
            bp_print_csv(stdout,&out);
        } else {
            bp_print_csv(stdout,&row);
        }
    }
    return 0;
}

/* 獨立執行入口（非 BusyBox 環境，不定義 BUSYBOX_BUILD 時編譯） */
#ifndef BUSYBOX_BUILD
int main(int argc, char **argv) { return lfilter_main(argc, argv); }
#endif
