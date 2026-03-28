/*
 * recalc_otd.c — Recalculador Batch de Alta Performance para OTD
 *
 * Uso:
 *   gcc -O2 -o recalc_otd recalc_otd.c -lm
 *   ./recalc_otd pedidos_export.csv > data.js
 *
 * Lê o CSV exportado pelo dashboard (Exportar Planilha → aba "Pedidos OTD")
 * e recomputa todos os campos derivados por mês, gerando um novo data.js.
 *
 * Separador: ; (ponto-e-vírgula), como o dashboard exporta.
 * Encoding: UTF-8.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <ctype.h>

#define MAX_PEDIDOS  100000
#define MAX_MONTHS   120
#define MAX_FIELDS   32
#define FLEN         512

/* ─── Estruturas ───────────────────────────────────────────────────────── */

typedef struct {
    int    pedido;
    char   cliente[FLEN];
    char   nomeFantasia[FLEN];
    char   vendedor[FLEN];
    char   gerente[FLEN];
    char   codProd[FLEN];
    char   descricao[FLEN];
    char   dtPedido[32];
    char   prevEnt[32];
    char   dtFat[32];
    int    dias;
    double vlrMerc;
    int    qtde;
    char   situacao[FLEN];
    int    nf;
    char   motivo[FLEN];
    char   mk[8];
} Pedido;

typedef struct {
    char   mk[8];
    char   label[64];
    int    totalPedidos;
    int    noPrazo;
    int    dataExata;
    int    adiantados;
    int    atrasados;
    int    ate5;
    int    mais5;
    double taxaOTD;
    int    distAtraso[7];  /* [1..5] = dias 1-5, [6] = n>5 */
    int    distAdiant[7];
} MonthSummary;

/* ─── Safe string copy (always null-terminated) ────────────────────────── */

static void safe_copy(char *dst, const char *src, size_t maxlen) {
    if (!src) { dst[0] = '\0'; return; }
    size_t len = strlen(src);
    if (len >= maxlen) len = maxlen - 1;
    memcpy(dst, src, len);
    dst[len] = '\0';
}

/* ─── Trim whitespace ──────────────────────────────────────────────────── */

static void trim(char *s) {
    char *end;
    while (isspace((unsigned char)*s)) s++;
    end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) *end-- = '\0';
}

/* ─── Date helpers ─────────────────────────────────────────────────────── */

static int parse_dmy(const char *s, int *day, int *mon, int *year) {
    /* Handles DD/MM/YYYY with 1 or 2 digit day/month */
    if (!s || !*s) return 0;
    if (sscanf(s, "%d/%d/%d", day, mon, year) == 3 &&
        *year > 1900 && *mon >= 1 && *mon <= 12 && *day >= 1 && *day <= 31)
        return 1;
    return 0;
}

static int calc_dias(const char *prev, const char *fat) {
    int d1, m1, y1, d2, m2, y2;
    if (!parse_dmy(prev, &d1, &m1, &y1)) return 0;
    if (!parse_dmy(fat,  &d2, &m2, &y2)) return 0;
    struct tm t1 = {0}, t2 = {0};
    t1.tm_year = y1 - 1900; t1.tm_mon = m1 - 1; t1.tm_mday = d1;
    t2.tm_year = y2 - 1900; t2.tm_mon = m2 - 1; t2.tm_mday = d2;
    time_t tt1 = mktime(&t1), tt2 = mktime(&t2);
    if (tt1 == (time_t)-1 || tt2 == (time_t)-1) return 0;
    return (int)round(difftime(tt2, tt1) / 86400.0);
}

/* ─── CSV parser (;-delimited, handles quoted fields) ──────────────────── */

static int parse_csv_line(char *line, char out[][FLEN], int max_fields) {
    int count = 0;
    char *p = line;
    while (count < max_fields && *p && *p != '\n' && *p != '\r') {
        int fi = 0;
        out[count][0] = '\0';
        if (*p == '"') {
            p++;
            while (*p) {
                if (*p == '"') {
                    if (*(p + 1) == '"') { if (fi < FLEN - 1) out[count][fi++] = '"'; p += 2; }
                    else { p++; break; }
                } else {
                    if (fi < FLEN - 1) out[count][fi++] = *p;
                    p++;
                }
            }
            if (*p == ';') p++;
        } else {
            while (*p && *p != ';' && *p != '\n' && *p != '\r') {
                if (fi < FLEN - 1) out[count][fi++] = *p;
                p++;
            }
            if (*p == ';') p++;
        }
        out[count][fi] = '\0';
        count++;
    }
    return count;
}

/* ─── JSON escape ──────────────────────────────────────────────────────── */

static void json_escape(const char *s, char *out, size_t maxlen) {
    size_t j = 0;
    for (size_t i = 0; s[i] && j < maxlen - 6; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"':  out[j++] = '\\'; out[j++] = '"'; break;
            case '\\': out[j++] = '\\'; out[j++] = '\\'; break;
            case '\n': out[j++] = '\\'; out[j++] = 'n'; break;
            case '\r': out[j++] = '\\'; out[j++] = 'r'; break;
            case '\t': out[j++] = '\\'; out[j++] = 't'; break;
            default:   out[j++] = c; break;
        }
    }
    out[j] = '\0';
}

/* ─── Column mapping ───────────────────────────────────────────────────── */

typedef struct {
    int mes, pedido, cnpj, cliente, gerente, vendedor;
    int codprod, descricao, dtPedido, prevEnt, dtFat;
    int dias, vlrMerc, qtde, situacao, nf, motivo;
} ColMap;

static int find_col(char fields[][FLEN], int n, const char *name) {
    for (int i = 0; i < n; i++) {
        char buf[FLEN];
        safe_copy(buf, fields[i], FLEN);
        trim(buf);
        /* Case-insensitive comparison (ASCII only) */
        int match = 1;
        const char *a = buf, *b = name;
        while (*a && *b) {
            if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) { match = 0; break; }
            a++; b++;
        }
        if (match && !*a && !*b) return i;
    }
    return -1;
}

static ColMap map_columns(char fields[][FLEN], int n) {
    ColMap cm;
    memset(&cm, -1, sizeof(cm));
    cm.mes       = find_col(fields, n, "Mês");
    if (cm.mes < 0) cm.mes = find_col(fields, n, "Mes");
    cm.pedido    = find_col(fields, n, "Pedido");
    cm.cnpj      = find_col(fields, n, "CNPJ/Cód.");
    if (cm.cnpj < 0) cm.cnpj = find_col(fields, n, "CNPJ/Cod.");
    cm.cliente   = find_col(fields, n, "Cliente");
    cm.gerente   = find_col(fields, n, "Gerente");
    cm.vendedor  = find_col(fields, n, "Vendedor");
    cm.codprod   = find_col(fields, n, "Cód. Produto");
    if (cm.codprod < 0) cm.codprod = find_col(fields, n, "Cod. Produto");
    cm.descricao = find_col(fields, n, "Produto");
    cm.dtPedido  = find_col(fields, n, "Dt. Pedido");
    cm.prevEnt   = find_col(fields, n, "Prev. Entrega");
    cm.dtFat     = find_col(fields, n, "Dt. Faturamento");
    cm.dias      = find_col(fields, n, "DIAS");
    cm.vlrMerc   = find_col(fields, n, "Valor (R$)");
    cm.qtde      = find_col(fields, n, "Qtde");
    cm.situacao  = find_col(fields, n, "Situação");
    if (cm.situacao < 0) cm.situacao = find_col(fields, n, "Situacao");
    cm.nf        = find_col(fields, n, "NF");
    cm.motivo    = find_col(fields, n, "Motivo Atraso");
    return cm;
}

/* ─── Month names ──────────────────────────────────────────────────────── */

static const char *MES_NAMES[] = {
    "Janeiro","Fevereiro","Março","Abril","Maio","Junho",
    "Julho","Agosto","Setembro","Outubro","Novembro","Dezembro"
};

static void build_label(const char *mk, char *label, size_t len) {
    int y, mo;
    if (sscanf(mk, "%d-%d", &y, &mo) == 2 && mo >= 1 && mo <= 12)
        snprintf(label, len, "%s %d", MES_NAMES[mo - 1], y);
    else
        safe_copy(label, mk, len);
}

/* ─── Globals ──────────────────────────────────────────────────────────── */

static Pedido       g_pedidos[MAX_PEDIDOS];
static MonthSummary g_months[MAX_MONTHS];
static char         g_mkeys[MAX_MONTHS][8];
static int          g_nPed = 0, g_nMon = 0;

static int find_or_add_month(const char *mk) {
    for (int i = 0; i < g_nMon; i++)
        if (strcmp(g_mkeys[i], mk) == 0) return i;
    if (g_nMon >= MAX_MONTHS) return -1;
    safe_copy(g_mkeys[g_nMon], mk, 8);
    memset(&g_months[g_nMon], 0, sizeof(MonthSummary));
    safe_copy(g_months[g_nMon].mk, mk, 8);
    build_label(mk, g_months[g_nMon].label, sizeof(g_months[g_nMon].label));
    return g_nMon++;
}

/* ─── Main ─────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Uso: %s pedidos_export.csv > data.js\n", argv[0]);
        return 1;
    }
    FILE *fp = fopen(argv[1], "r");
    if (!fp) { perror("Erro ao abrir arquivo"); return 1; }

    char line[8192];
    char fields[MAX_FIELDS][FLEN];
    ColMap cm;
    int header_done = 0;

    while (fgets(line, sizeof(line), fp)) {
        int n = parse_csv_line(line, fields, MAX_FIELDS);
        if (n < 2) continue;
        if (!header_done) {
            cm = map_columns(fields, n);
            header_done = 1;
            if (cm.pedido < 0) { fprintf(stderr, "Erro: coluna 'Pedido' não encontrada.\n"); fclose(fp); return 1; }
            continue;
        }
        if (g_nPed >= MAX_PEDIDOS) { fprintf(stderr, "Aviso: limite de %d pedidos atingido.\n", MAX_PEDIDOS); break; }

        int pnum = cm.pedido >= 0 ? atoi(fields[cm.pedido]) : 0;
        if (!pnum) continue;

        Pedido *p = &g_pedidos[g_nPed];
        memset(p, 0, sizeof(Pedido));
        p->pedido = pnum;

        if (cm.cnpj >= 0)      safe_copy(p->cliente,     fields[cm.cnpj],     FLEN);
        if (cm.cliente >= 0)   safe_copy(p->nomeFantasia, fields[cm.cliente],  FLEN);
        if (cm.vendedor >= 0)  safe_copy(p->vendedor,     fields[cm.vendedor], FLEN);
        if (cm.gerente >= 0)   safe_copy(p->gerente,      fields[cm.gerente],  FLEN);
        if (cm.codprod >= 0)   safe_copy(p->codProd,      fields[cm.codprod],  FLEN);
        if (cm.descricao >= 0) safe_copy(p->descricao,    fields[cm.descricao],FLEN);
        if (cm.dtPedido >= 0)  safe_copy(p->dtPedido,     fields[cm.dtPedido], 31);
        if (cm.prevEnt >= 0)   safe_copy(p->prevEnt,      fields[cm.prevEnt],  31);
        if (cm.dtFat >= 0)     safe_copy(p->dtFat,        fields[cm.dtFat],    31);
        if (cm.situacao >= 0)  safe_copy(p->situacao,     fields[cm.situacao], FLEN);
        if (cm.motivo >= 0)    safe_copy(p->motivo,       fields[cm.motivo],   FLEN);
        p->nf      = cm.nf >= 0    ? atoi(fields[cm.nf])    : 0;
        p->qtde    = cm.qtde >= 0  ? atoi(fields[cm.qtde])  : 0;
        p->vlrMerc = cm.vlrMerc >= 0 ? atof(fields[cm.vlrMerc]) : 0.0;

        /* Calcular DIAS via datas — recalcula sempre para consistência */
        if (p->prevEnt[0] && p->dtFat[0])
            p->dias = calc_dias(p->prevEnt, p->dtFat);
        else if (cm.dias >= 0)
            p->dias = atoi(fields[cm.dias]);

        /* mk = YYYY-MM from dtPedido */
        if (strlen(p->dtPedido) >= 7) {
            memcpy(p->mk, p->dtPedido, 7);
            p->mk[7] = '\0';
        } else continue;

        if (strcmp(p->mk, "0000-00") == 0) continue;
        if (find_or_add_month(p->mk) < 0) continue;
        g_nPed++;
    }
    fclose(fp);

    /* Sort months */
    for (int i = 0; i < g_nMon - 1; i++)
        for (int j = i + 1; j < g_nMon; j++)
            if (strcmp(g_mkeys[i], g_mkeys[j]) > 0) {
                char tmp[8]; memcpy(tmp, g_mkeys[i], 8); memcpy(g_mkeys[i], g_mkeys[j], 8); memcpy(g_mkeys[j], tmp, 8);
                MonthSummary ms = g_months[i]; g_months[i] = g_months[j]; g_months[j] = ms;
            }

    /* Aggregate */
    for (int pi = 0; pi < g_nPed; pi++) {
        Pedido *p = &g_pedidos[pi];
        for (int mi = 0; mi < g_nMon; mi++) {
            if (strcmp(g_months[mi].mk, p->mk) != 0) continue;
            MonthSummary *ms = &g_months[mi];
            ms->totalPedidos++;
            if (p->dias <= 0) ms->noPrazo++;
            if (p->dias == 0) ms->dataExata++;
            if (p->dias < 0)  ms->adiantados++;
            if (p->dias > 0)  ms->atrasados++;
            if (p->dias >= 1 && p->dias <= 5) ms->ate5++;
            if (p->dias > 5)  ms->mais5++;
            if (p->dias >= 1 && p->dias <= 5) ms->distAtraso[p->dias]++;
            else if (p->dias > 5)             ms->distAtraso[6]++;
            int ad = -p->dias;
            if (ad >= 1 && ad <= 5) ms->distAdiant[ad]++;
            else if (ad > 5)       ms->distAdiant[6]++;
            break;
        }
    }

    for (int mi = 0; mi < g_nMon; mi++) {
        MonthSummary *ms = &g_months[mi];
        ms->taxaOTD = ms->totalPedidos > 0
            ? round((double)ms->noPrazo / ms->totalPedidos * 10000.0) / 100.0
            : 0.0;
    }

    /* Output data.js */
    time_t now = time(NULL);
    char iso[32];
    strftime(iso, sizeof(iso), "%Y-%m-%dT%H:%M:%S", localtime(&now));

    printf("// Dashboard OTD — Dados recalculados em %s\n", iso);
    printf("// Gerado por recalc_otd.c\n");
    printf("console.log(\"Carregando otdData...\");\n");
    printf("window.otdData = {\n  \"exportedAt\": \"%s\",\n  \"months\": {\n", iso);

    char esc[FLEN * 2];
    for (int mi = 0; mi < g_nMon; mi++) {
        MonthSummary *ms = &g_months[mi];
        json_escape(ms->label, esc, sizeof(esc));
        printf("    \"%s\": {\n", ms->mk);
        printf("      \"label\": \"%s\",\n", esc);
        printf("      \"totalPedidos\": %d,\n\"pedidosNoPrazo\": %d,\n\"taxaOTD\": %.2f,\n",
               ms->totalPedidos, ms->noPrazo, ms->taxaOTD);
        printf("      \"pedidosDataExata\": %d,\n\"pedidosAdiantados\": %d,\n\"pedidosAtrasados\": %d,\n",
               ms->dataExata, ms->adiantados, ms->atrasados);
        printf("      \"pedidosAte5DiasAtraso\": %d,\n\"pedidosMais5DiasAtraso\": %d,\n",
               ms->ate5, ms->mais5);
        printf("      \"distribuicaoAtraso\": {\"1\":%d,\"2\":%d,\"3\":%d,\"4\":%d,\"5\":%d,\"n>5\":%d},\n",
               ms->distAtraso[1], ms->distAtraso[2], ms->distAtraso[3],
               ms->distAtraso[4], ms->distAtraso[5], ms->distAtraso[6]);
        printf("      \"distribuicaoAdiantamento\": {\"1\":%d,\"2\":%d,\"3\":%d,\"4\":%d,\"5\":%d,\"n>5\":%d},\n",
               ms->distAdiant[1], ms->distAdiant[2], ms->distAdiant[3],
               ms->distAdiant[4], ms->distAdiant[5], ms->distAdiant[6]);
        printf("      \"pedidos\": [\n");

        int first = 1;
        for (int pi = 0; pi < g_nPed; pi++) {
            Pedido *p = &g_pedidos[pi];
            if (strcmp(p->mk, ms->mk) != 0) continue;
            if (!first) printf(",\n");
            first = 0;
            char ec[FLEN*2], en[FLEN*2], ev[FLEN*2], eg[FLEN*2],
                 ep[FLEN*2], ed[FLEN*2], em[FLEN*2], es[FLEN*2];
            json_escape(p->cliente,     ec, sizeof(ec));
            json_escape(p->nomeFantasia,en, sizeof(en));
            json_escape(p->vendedor,    ev, sizeof(ev));
            json_escape(p->gerente,     eg, sizeof(eg));
            json_escape(p->codProd,     ep, sizeof(ep));
            json_escape(p->descricao,   ed, sizeof(ed));
            json_escape(p->motivo,      em, sizeof(em));
            json_escape(p->situacao,    es, sizeof(es));
            printf("        {\"pedido\":%d,\"cliente\":\"%s\",\"nomeFantasia\":\"%s\","
                   "\"vendedor\":\"%s\",\"gerente\":\"%s\","
                   "\"codProd\":\"%s\",\"descricao\":\"%s\","
                   "\"dtPedido\":\"%s\",\"prevEnt\":\"%s\",\"dtFat\":\"%s\","
                   "\"dias\":%d,\"vlrMerc\":%.2f,\"qtde\":%d,"
                   "\"situacao\":\"%s\",\"nf\":%d}",
                   p->pedido, ec, en, ev, eg, ep, ed,
                   p->dtPedido, p->prevEnt, p->dtFat,
                   p->dias, p->vlrMerc, p->qtde, es, p->nf);
        }
        printf("\n      ]\n    }%s\n", mi < g_nMon - 1 ? "," : "");
    }
    printf("  }\n};\n");

    fprintf(stderr, "OK: %d pedidos em %d meses processados.\n", g_nPed, g_nMon);
    return 0;
}
