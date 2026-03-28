/*
 * recalc_otd.c — Recalculador Batch de Alta Performance para OTD
 *
 * Uso:
 *   gcc -o recalc_otd recalc_otd.c
 *   ./recalc_otd pedidos_export.csv > data.js
 *
 * Lê o CSV exportado pelo dashboard (Exportar Planilha → aba "Pedidos OTD")
 * e recomputa todos os campos derivados por mês, gerando um novo data.js.
 *
 * Colunas esperadas no CSV (primeira linha = cabeçalho):
 *   Mês;Pedido;CNPJ/Cód.;Cliente;Gerente;Vendedor;Cód. Produto;Produto;
 *   Dt. Pedido;Prev. Entrega;Dt. Faturamento;DIAS;Status OTD;
 *   Valor (R$);Qtde;Situação;NF;Motivo Atraso
 *
 * Por que C:
 *   - mktime + difftime em <time.h> é timezone-naive para aritmética de datas
 *   - Evita bugs de serial number do Excel que afetam Date() no JavaScript
 *   - < 10ms mesmo com dezenas de milhares de pedidos
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

#define MAX_PEDIDOS 100000
#define MAX_MONTHS  120
#define FIELD_LEN   256

/* ─── Estruturas de dados ──────────────────────────────────────────────── */

typedef struct {
    int day, month, year;
} Date;

typedef struct {
    int    pedido;
    char   cliente[FIELD_LEN];
    char   nomeFantasia[FIELD_LEN];
    char   vendedor[FIELD_LEN];
    char   gerente[FIELD_LEN];
    char   codProd[FIELD_LEN];
    char   descricao[FIELD_LEN];
    char   dtPedido[32];    /* YYYY-MM-DD */
    char   prevEnt[32];     /* DD/MM/YYYY */
    char   dtFat[32];       /* DD/MM/YYYY */
    int    dias;
    double vlrMerc;
    int    qtde;
    char   situacao[FIELD_LEN];
    int    nf;
    char   motivo[FIELD_LEN];
    char   mk[8];           /* YYYY-MM */
} Pedido;

typedef struct {
    char   mk[8];
    char   label[64];
    int    totalPedidos;
    int    pedidosNoPrazo;
    int    pedidosDataExata;
    int    pedidosAdiantados;
    int    pedidosAtrasados;
    int    pedidosAte5DiasAtraso;
    int    pedidosMais5DiasAtraso;
    double taxaOTD;
    int    distAtraso[8];   /* índices 1..5 = 1..5 dias, índice 6 = n>5 */
    int    distAdiant[8];
} MonthSummary;

/* ─── Helpers de data ──────────────────────────────────────────────────── */

static int parse_date_dmy(const char *s, Date *out) {
    /* Formato DD/MM/YYYY */
    if (strlen(s) < 10) return 0;
    char buf[11];
    strncpy(buf, s, 10); buf[10] = '\0';
    if (sscanf(buf, "%2d/%2d/%4d", &out->day, &out->month, &out->year) != 3) return 0;
    return (out->year > 1900 && out->month >= 1 && out->month <= 12 && out->day >= 1 && out->day <= 31);
}

static time_t date_to_time(const Date *d) {
    struct tm t;
    memset(&t, 0, sizeof(t));
    t.tm_year = d->year - 1900;
    t.tm_mon  = d->month - 1;
    t.tm_mday = d->day;
    return mktime(&t);
}

/*
 * Calcula DIAS = dtFat - prevEnt usando aritmética de calendário pura.
 * mktime normaliza a data automaticamente (sem ambiguidade de horário de verão).
 */
static int calc_dias(const char *prev_ent, const char *dt_fat) {
    Date d1, d2;
    if (!parse_date_dmy(prev_ent, &d1)) return 0;
    if (!parse_date_dmy(dt_fat,   &d2)) return 0;
    time_t t1 = date_to_time(&d1);
    time_t t2 = date_to_time(&d2);
    if (t1 == (time_t)-1 || t2 == (time_t)-1) return 0;
    return (int)round(difftime(t2, t1) / 86400.0);
}

/* ─── Parser CSV simples (separador ;) ─────────────────────────────────── */

static int split_csv_line(char *line, char fields[][FIELD_LEN], int max_fields) {
    int count = 0;
    char *p = line;
    while (count < max_fields) {
        char *start = p;
        int in_quote = 0;
        fields[count][0] = '\0';
        int fi = 0;
        while (*p) {
            if (*p == '"') { in_quote = !in_quote; p++; continue; }
            if (*p == ';' && !in_quote) { p++; break; }
            if (*p == '\n' || *p == '\r') { p++; break; }
            if (fi < FIELD_LEN - 1) fields[count][fi++] = *p;
            p++;
        }
        fields[count][fi] = '\0';
        count++;
        if (!*p || *p == '\n' || *p == '\r') break;
    }
    return count;
}

/* Remove trailing whitespace/newline */
static void rtrim(char *s) {
    int n = strlen(s);
    while (n > 0 && (s[n-1] == '\n' || s[n-1] == '\r' || s[n-1] == ' ')) s[--n] = '\0';
}

/* ─── Mapeamento de colunas ────────────────────────────────────────────── */
typedef struct {
    int mes, pedido, cnpj, cliente, gerente, vendedor, codprod, descricao;
    int dtPedido, prevEnt, dtFat, dias, vlrMerc, qtde, situacao, nf, motivo;
} ColMap;

static int find_col(char fields[][FIELD_LEN], int n, const char *name) {
    for (int i = 0; i < n; i++) {
        if (strcasecmp(fields[i], name) == 0) return i;
    }
    return -1;
}

static ColMap map_columns(char fields[][FIELD_LEN], int n) {
    ColMap cm;
    cm.mes       = find_col(fields, n, "Mês");
    cm.pedido    = find_col(fields, n, "Pedido");
    cm.cnpj      = find_col(fields, n, "CNPJ/Cód.");
    cm.cliente   = find_col(fields, n, "Cliente");
    cm.gerente   = find_col(fields, n, "Gerente");
    cm.vendedor  = find_col(fields, n, "Vendedor");
    cm.codprod   = find_col(fields, n, "Cód. Produto");
    cm.descricao = find_col(fields, n, "Produto");
    cm.dtPedido  = find_col(fields, n, "Dt. Pedido");
    cm.prevEnt   = find_col(fields, n, "Prev. Entrega");
    cm.dtFat     = find_col(fields, n, "Dt. Faturamento");
    cm.dias      = find_col(fields, n, "DIAS");
    cm.vlrMerc   = find_col(fields, n, "Valor (R$)");
    cm.qtde      = find_col(fields, n, "Qtde");
    cm.situacao  = find_col(fields, n, "Situação");
    cm.nf        = find_col(fields, n, "NF");
    cm.motivo    = find_col(fields, n, "Motivo Atraso");
    return cm;
}

/* ─── Meses ─────────────────────────────────────────────────────────────── */

static const char *MES_NAMES[] = {
    "Janeiro","Fevereiro","Março","Abril","Maio","Junho",
    "Julho","Agosto","Setembro","Outubro","Novembro","Dezembro"
};

static void build_label(const char *mk, char *label, size_t len) {
    int y, mo;
    if (sscanf(mk, "%4d-%2d", &y, &mo) == 2 && mo >= 1 && mo <= 12)
        snprintf(label, len, "%s %d", MES_NAMES[mo-1], y);
    else
        strncpy(label, mk, len);
}

/* ─── Escape JSON string ─────────────────────────────────────────────────── */

static void json_escape(const char *s, char *out, size_t maxlen) {
    size_t i = 0, j = 0;
    while (s[i] && j < maxlen - 4) {
        unsigned char c = s[i++];
        if      (c == '"')  { out[j++]='\\'; out[j++]='"'; }
        else if (c == '\\') { out[j++]='\\'; out[j++]='\\'; }
        else if (c == '\n') { out[j++]='\\'; out[j++]='n'; }
        else if (c == '\r') { out[j++]='\\'; out[j++]='r'; }
        else if (c == '\t') { out[j++]='\\'; out[j++]='t'; }
        else                { out[j++]=c; }
    }
    out[j] = '\0';
}

/* ─── Main ──────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    FILE *fp;
    if (argc < 2) {
        fprintf(stderr, "Uso: %s pedidos_export.csv > data.js\n", argv[0]);
        return 1;
    }
    fp = fopen(argv[1], "r");
    if (!fp) { perror("Erro ao abrir arquivo"); return 1; }

    static Pedido pedidos[MAX_PEDIDOS];
    static MonthSummary months[MAX_MONTHS];
    static char month_keys[MAX_MONTHS][8];
    int nPedidos = 0, nMonths = 0;

    char line[4096];
    char fields[32][FIELD_LEN];
    ColMap cm = {0};
    int header_done = 0;

    /* ── Leitura do CSV ─────────────────────────────────────────────────── */
    while (fgets(line, sizeof(line), fp)) {
        rtrim(line);
        if (!line[0]) continue;
        int n = split_csv_line(line, fields, 32);
        if (!header_done) {
            cm = map_columns(fields, n);
            header_done = 1;
            if (cm.pedido < 0) { fprintf(stderr,"Coluna PEDIDO não encontrada\n"); return 1; }
            continue;
        }
        if (nPedidos >= MAX_PEDIDOS) { fprintf(stderr,"Limite de pedidos atingido\n"); break; }

        int pnum = cm.pedido >= 0 ? atoi(fields[cm.pedido]) : 0;
        if (!pnum) continue;

        Pedido *p = &pedidos[nPedidos];
        memset(p, 0, sizeof(Pedido));
        p->pedido = pnum;
        if (cm.cnpj >= 0)      strncpy(p->cliente,     fields[cm.cnpj],     FIELD_LEN-1);
        if (cm.cliente >= 0)   strncpy(p->nomeFantasia, fields[cm.cliente],  FIELD_LEN-1);
        if (cm.vendedor >= 0)  strncpy(p->vendedor,     fields[cm.vendedor], FIELD_LEN-1);
        if (cm.gerente >= 0)   strncpy(p->gerente,      fields[cm.gerente],  FIELD_LEN-1);
        if (cm.codprod >= 0)   strncpy(p->codProd,      fields[cm.codprod],  FIELD_LEN-1);
        if (cm.descricao >= 0) strncpy(p->descricao,    fields[cm.descricao],FIELD_LEN-1);
        if (cm.dtPedido >= 0)  strncpy(p->dtPedido,     fields[cm.dtPedido], 31);
        if (cm.prevEnt >= 0)   strncpy(p->prevEnt,      fields[cm.prevEnt],  31);
        if (cm.dtFat >= 0)     strncpy(p->dtFat,        fields[cm.dtFat],    31);
        if (cm.situacao >= 0)  strncpy(p->situacao,     fields[cm.situacao], FIELD_LEN-1);
        if (cm.motivo >= 0)    strncpy(p->motivo,       fields[cm.motivo],   FIELD_LEN-1);
        p->nf      = cm.nf >= 0    ? atoi(fields[cm.nf])    : 0;
        p->qtde    = cm.qtde >= 0  ? atoi(fields[cm.qtde])  : 0;
        p->vlrMerc = cm.vlrMerc >= 0 ? atof(fields[cm.vlrMerc]) : 0.0;

        /* Calcular DIAS via aritmética de datas (evita bugs de timezone) */
        if (p->prevEnt[0] && p->dtFat[0])
            p->dias = calc_dias(p->prevEnt, p->dtFat);
        else if (cm.dias >= 0)
            p->dias = atoi(fields[cm.dias]);

        /* Extrair mk = YYYY-MM de dtPedido (YYYY-MM-DD) */
        if (strlen(p->dtPedido) >= 7) {
            strncpy(p->mk, p->dtPedido, 7); p->mk[7] = '\0';
        } else {
            strncpy(p->mk, "0000-00", 7);
        }
        if (strcmp(p->mk, "0000-00") == 0) continue;

        /* Registrar mk se novo */
        int found = 0;
        for (int i = 0; i < nMonths; i++) {
            if (strcmp(month_keys[i], p->mk) == 0) { found = 1; break; }
        }
        if (!found && nMonths < MAX_MONTHS) {
            strncpy(month_keys[nMonths], p->mk, 7);
            memset(&months[nMonths], 0, sizeof(MonthSummary));
            strncpy(months[nMonths].mk, p->mk, 7);
            build_label(p->mk, months[nMonths].label, sizeof(months[nMonths].label));
            nMonths++;
        }
        nPedidos++;
    }
    fclose(fp);

    /* ── Ordenar meses ──────────────────────────────────────────────────── */
    for (int i = 0; i < nMonths - 1; i++)
        for (int j = i + 1; j < nMonths; j++)
            if (strcmp(month_keys[i], month_keys[j]) > 0) {
                char tmp[8]; strncpy(tmp, month_keys[i], 8);
                strncpy(month_keys[i], month_keys[j], 8);
                strncpy(month_keys[j], tmp, 8);
                MonthSummary ms = months[i]; months[i] = months[j]; months[j] = ms;
            }

    /* ── Agregar pedidos por mês ────────────────────────────────────────── */
    for (int pi = 0; pi < nPedidos; pi++) {
        Pedido *p = &pedidos[pi];
        for (int mi = 0; mi < nMonths; mi++) {
            if (strcmp(months[mi].mk, p->mk) != 0) continue;
            MonthSummary *ms = &months[mi];
            ms->totalPedidos++;
            if (p->dias <= 0) ms->pedidosNoPrazo++;
            if (p->dias == 0) ms->pedidosDataExata++;
            if (p->dias < 0)  ms->pedidosAdiantados++;
            if (p->dias > 0)  ms->pedidosAtrasados++;
            if (p->dias >= 1 && p->dias <= 5) ms->pedidosAte5DiasAtraso++;
            if (p->dias > 5)  ms->pedidosMais5DiasAtraso++;
            /* distribuicaoAtraso[1..5] e [6]=n>5 */
            if (p->dias >= 1 && p->dias <= 5) ms->distAtraso[p->dias]++;
            else if (p->dias > 5)             ms->distAtraso[6]++;
            /* distribuicaoAdiantamento: dias negativos */
            int adias = -p->dias;
            if (adias >= 1 && adias <= 5) ms->distAdiant[adias]++;
            else if (adias > 5)           ms->distAdiant[6]++;
            break;
        }
    }

    /* ── Calcular taxaOTD ───────────────────────────────────────────────── */
    for (int mi = 0; mi < nMonths; mi++) {
        MonthSummary *ms = &months[mi];
        ms->taxaOTD = ms->totalPedidos > 0
            ? round((double)ms->pedidosNoPrazo / ms->totalPedidos * 10000.0) / 100.0
            : 0.0;
    }

    /* ── Emitir data.js ─────────────────────────────────────────────────── */
    time_t now = time(NULL);
    struct tm *lt = localtime(&now);
    char iso_now[32];
    strftime(iso_now, sizeof(iso_now), "%Y-%m-%dT%H:%M:%S", lt);

    printf("// Dashboard OTD — Dados recalculados em %s\n", iso_now);
    printf("// Gerado por recalc_otd.c (C batch recalculator)\n");
    printf("// Substitua este arquivo na raiz do repositório para atualizar os dados\n");
    printf("console.log(\"Carregando otdData...\");\n");
    printf("window.otdData = {\n");
    printf("  \"exportedAt\": \"%s\",\n", iso_now);
    printf("  \"months\": {\n");

    char esc[FIELD_LEN * 2];
    for (int mi = 0; mi < nMonths; mi++) {
        MonthSummary *ms = &months[mi];
        json_escape(ms->label, esc, sizeof(esc));
        printf("    \"%s\": {\n", ms->mk);
        printf("      \"label\": \"%s\",\n", esc);
        printf("      \"totalPedidos\": %d,\n",            ms->totalPedidos);
        printf("      \"pedidosNoPrazo\": %d,\n",          ms->pedidosNoPrazo);
        printf("      \"taxaOTD\": %.2f,\n",               ms->taxaOTD);
        printf("      \"pedidosDataExata\": %d,\n",        ms->pedidosDataExata);
        printf("      \"pedidosAdiantados\": %d,\n",       ms->pedidosAdiantados);
        printf("      \"pedidosAtrasados\": %d,\n",        ms->pedidosAtrasados);
        printf("      \"pedidosAte5DiasAtraso\": %d,\n",   ms->pedidosAte5DiasAtraso);
        printf("      \"pedidosMais5DiasAtraso\": %d,\n",  ms->pedidosMais5DiasAtraso);
        printf("      \"distribuicaoAtraso\": {\"1\":%d,\"2\":%d,\"3\":%d,\"4\":%d,\"5\":%d,\"n>5\":%d},\n",
               ms->distAtraso[1], ms->distAtraso[2], ms->distAtraso[3],
               ms->distAtraso[4], ms->distAtraso[5], ms->distAtraso[6]);
        printf("      \"distribuicaoAdiantamento\": {\"1\":%d,\"2\":%d,\"3\":%d,\"4\":%d,\"5\":%d,\"n>5\":%d},\n",
               ms->distAdiant[1], ms->distAdiant[2], ms->distAdiant[3],
               ms->distAdiant[4], ms->distAdiant[5], ms->distAdiant[6]);
        printf("      \"pedidos\": [\n");

        int first_ped = 1;
        for (int pi = 0; pi < nPedidos; pi++) {
            Pedido *p = &pedidos[pi];
            if (strcmp(p->mk, ms->mk) != 0) continue;
            if (!first_ped) printf(",\n");
            first_ped = 0;
            char ce[FIELD_LEN*2], nf2[FIELD_LEN*2], vend[FIELD_LEN*2],
                 ger[FIELD_LEN*2], prod[FIELD_LEN*2], desc[FIELD_LEN*2],
                 mot[FIELD_LEN*2], sit[FIELD_LEN*2];
            json_escape(p->cliente,     ce,   sizeof(ce));
            json_escape(p->nomeFantasia,nf2,  sizeof(nf2));
            json_escape(p->vendedor,    vend, sizeof(vend));
            json_escape(p->gerente,     ger,  sizeof(ger));
            json_escape(p->codProd,     prod, sizeof(prod));
            json_escape(p->descricao,   desc, sizeof(desc));
            json_escape(p->motivo,      mot,  sizeof(mot));
            json_escape(p->situacao,    sit,  sizeof(sit));
            printf("        {\"pedido\":%d,\"cliente\":\"%s\",\"nomeFantasia\":\"%s\","
                   "\"vendedor\":\"%s\",\"gerente\":\"%s\","
                   "\"codProd\":\"%s\",\"descricao\":\"%s\","
                   "\"dtPedido\":\"%s\",\"prevEnt\":\"%s\",\"dtFat\":\"%s\","
                   "\"dias\":%d,\"vlrMerc\":%.2f,\"qtde\":%d,"
                   "\"situacao\":\"%s\",\"nf\":%d,\"_motivoText\":\"%s\",\"_motAuto\":false}",
                   p->pedido, ce, nf2, vend, ger, prod, desc,
                   p->dtPedido, p->prevEnt, p->dtFat,
                   p->dias, p->vlrMerc, p->qtde, sit, p->nf, mot);
        }
        printf("\n      ]\n");
        printf("    }%s\n", mi < nMonths - 1 ? "," : "");
    }

    printf("  }\n};\n");
    return 0;
}
