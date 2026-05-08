#!/bin/bash
# ============================================================================
#  openedgezbx_collector.sh
#  --------------------------------------------------------------------------
#  Script de coleta automatizada de métricas de TODOS os bancos Progress
#  OpenEdge carregados no servidor local.
#
#  Fluxo:
#    1) Verifica se o arquivo .env existe; se não, executa setup interativo
#    2) Carrega configurações do .env
#    3) Executa $DLC/bin/dbipcs para listar bancos em shared memory
#    4) Extrai os caminhos únicos dos bancos carregados
#    5) Para cada banco, executa openedgezbx.p via _progres em batch
#    6) Salva o JSON em <script_dir>/json_zbx/<nome_banco>.json
#
#  Uso:
#    chmod +x openedgezbx_collector.sh
#    ./openedgezbx_collector.sh                 (coleta normal)
#    ./openedgezbx_collector.sh debug           (JSON com metadados)
#    ./openedgezbx_collector.sh setup           (força reconfiguração)
#
#  Setup:
#    Na primeira execução (ou quando o .env não existir), o script
#    solicita interativamente os parâmetros e grava no arquivo
#    openedgezbx_collector.env. Para reconfigurar, delete o .env
#    ou execute com argumento "setup".
#
#  Compatível com: Linux (bash), OpenEdge 12.2+
# ============================================================================

# === VARIÁVEIS DO SCRIPT =====================================================

# Diretório deste script (referência para todos os caminhos relativos)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Nome base do script (sem extensão) — usado para nomear o .env
SCRIPT_BASE=$(basename "$0" .sh)

# Arquivo de configuração (.env) — mesmo nome do script com extensão .env
ENV_FILE="$SCRIPT_DIR/${SCRIPT_BASE}.env"

# Diretório de saída dos JSONs — dentro do diretório do script
JSON_DIR="$SCRIPT_DIR/json_zbx"

# === FUNÇÃO: SETUP INTERATIVO ================================================
#  Solicita parâmetros ao usuário e grava no arquivo .env.
#  Executado automaticamente na primeira execução ou quando
#  o .env não existir. Pode ser forçado com argumento "setup".
# =============================================================================

run_setup() {
    echo ""
    echo "============================================================"
    echo "  openedgezbx — Setup de configuração inicial"
    echo "============================================================"
    echo ""
    echo "  O arquivo de configuração não foi encontrado."
    echo "  Responda as perguntas abaixo para configurar o coletor."
    echo "  As configurações serão salvas em:"
    echo "    $ENV_FILE"
    echo ""

    # --- DLC (diretório de instalação do OpenEdge) ---
    local default_dlc="/usr/dlc"
    if [ -n "$DLC" ] && [ -d "$DLC" ]; then
        default_dlc="$DLC"
    fi
    read -rp "  Caminho do DLC (instalação OpenEdge) [$default_dlc]: " input_dlc
    input_dlc="${input_dlc:-$default_dlc}"

    # Valida se o diretório existe
    if [ ! -d "$input_dlc" ]; then
        echo ""
        echo "  [AVISO] O diretório '$input_dlc' não existe neste momento."
        read -rp "  Deseja continuar mesmo assim? (s/N): " confirm
        if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
            echo "  Setup cancelado."
            exit 1
        fi
    fi

    # --- PROPATH adicional (opcional) ---
    read -rp "  PROPATH adicional (opcional, Enter para pular): " input_propath
    input_propath="${input_propath:-}"

    # --- Usuário do banco (opcional, para conexão) ---
    read -rp "  Usuário do banco (opcional, Enter para pular): " input_dbuser
    input_dbuser="${input_dbuser:-}"

    # --- Senha do banco (opcional) ---
    local input_dbpass=""
    if [ -n "$input_dbuser" ]; then
        read -srp "  Senha do banco (opcional, Enter para pular): " input_dbpass
        echo ""
    fi

    # --- Parâmetros extras para _progres (opcional) ---
    echo ""
    echo "  Parâmetros extras são passados diretamente ao mpro."
    echo "  Exemplo: -cpinternal UTF-8 -cpstream UTF-8"
    read -rp "  Parâmetros extras para mpro (opcional): " input_extra_params
    input_extra_params="${input_extra_params:-}"

    # --- Filtro de diretórios permitidos ---
    echo ""
    echo "  ================================================================"
    echo "  FILTRO DE DIRETÓRIOS"
    echo "  ----------------------------------------------------------------"
    echo "  Permite restringir a coleta a diretórios específicos."
    echo "  Exemplo: coletar apenas bancos de produção ou apenas de teste."
    echo ""
    echo "  Diretórios PERMITIDOS (include): se preenchido, SOMENTE bancos"
    echo "  nesses diretórios serão coletados. Separar com vírgula."
    echo "  Exemplo: /producao/bancos,/producao/bancos2"
    read -rp "  Diretórios permitidos (Enter = todos): " input_include_dirs
    input_include_dirs="${input_include_dirs:-}"

    echo ""
    echo "  Diretórios IGNORADOS (exclude): bancos nesses diretórios serão"
    echo "  sempre ignorados, mesmo que estejam nos permitidos."
    echo "  Exemplo: /teste/bancos,/desenvolvimento/bancos"
    read -rp "  Diretórios ignorados (Enter = nenhum): " input_exclude_dirs
    input_exclude_dirs="${input_exclude_dirs:-}"

    # --- Grava o arquivo .env ---
    cat > "$ENV_FILE" << ENVEOF
# ============================================================================
#  openedgezbx_collector.env
#  Gerado automaticamente pelo setup em $(date '+%Y-%m-%d %H:%M:%S')
#  Para reconfigurar, delete este arquivo e execute o script novamente.
# ============================================================================

# Caminho da instalação do OpenEdge (DLC)
DLC="$input_dlc"

# PROPATH adicional (diretórios extras separados por :)
PROPATH_EXTRA="$input_propath"

# Credenciais do banco (opcional — usado apenas se preenchido)
DB_USER="$input_dbuser"
DB_PASS="$input_dbpass"

# Parâmetros extras passados ao mpro (ex: -cpinternal UTF-8)
EXTRA_PARAMS="$input_extra_params"

# ============================================================================
#  FILTRO DE DIRETÓRIOS
#  --------------------------------------------------------------------------
#  Permite restringir quais bancos serão coletados com base no diretório.
#  Separe múltiplos diretórios com vírgula (sem espaços).
#
#  INCLUDE_DIRS: se preenchido, SOMENTE bancos nestes diretórios serão
#                coletados. Se vazio, todos os bancos carregados entram.
#
#  EXCLUDE_DIRS: bancos nestes diretórios serão SEMPRE ignorados,
#                mesmo que estejam nos diretórios permitidos.
#
#  Exemplos:
#    INCLUDE_DIRS="/producao/bancos,/producao/bancos2"
#    EXCLUDE_DIRS="/teste/bancos,/desenvolvimento/bancos,/tmp"
#
#  Pode editar manualmente este arquivo a qualquer momento.
# ============================================================================
INCLUDE_DIRS="$input_include_dirs"
EXCLUDE_DIRS="$input_exclude_dirs"
ENVEOF

    # Protege o arquivo (contém possíveis credenciais)
    chmod 600 "$ENV_FILE"

    echo ""
    echo "  [OK] Configuração salva em: $ENV_FILE"
    echo "       Permissões: 600 (somente owner lê/escreve)"
    echo ""
    echo "  Para reconfigurar a qualquer momento:"
    echo "    - Delete o arquivo .env, ou"
    echo "    - Execute: $0 setup"
    echo ""
    echo "============================================================"
    echo ""
}

# === FUNÇÃO: GERAR JSON OFFLINE COMPLETO =====================================
#  Gera JSON com TODAS as chaves que os templates Zabbix v1.3.1 esperam.
#  Sem isso, o Zabbix retorna "no data matches the specified path" no
#  preprocessing JSONPath para qualquer chave ausente.
#
#  Argumentos:
#    $1 = nome lógico do banco
#    $2 = caminho físico
#    $3 = arquivo de saída
#    $4 = motivo (string para o campo notes/errors)
# =============================================================================
gen_offline_json() {
    local _name="$1"
    local _path="$2"
    local _out="$3"
    local _reason="$4"
    local _now=$(date '+%Y-%m-%dT%H:%M:%S')
    local _host=$(hostname 2>/dev/null || echo "unknown")

    cat > "$_out" << OFFJSON
{"collector":{"name":"openedgezbx","version":"1.3.2","language":"Progress ABL","generated_at":"${_now}","status":"error"},"database":{"logical_name":"${_name}","physical_name":"${_path}","physical_path":"${_path}","host":"${_host}","openedge_version":"unknown","db_status":"offline","pid":0,"uptime_seconds":0,"active_connections":0,"notes":"${_reason}"},"summary":{"health_status":"critical","error_count":1,"warning_count":0},"metrics":{"io":{"buffer_hit_ratio":0,"physical_reads_per_sec":0,"physical_writes_per_sec":0,"checkpoint_frequency_per_min":0,"db_block_size":0,"hi_water_total_blocks":0,"free_blocks":0,"logical_reads_total":0,"physical_reads_total":0,"db_writes_total":0,"areas_count":0,"log_file_size_mb":0,"log_file_size_bytes":0,"bi_log_size_gb":0,"bi_log_usage_percent":0,"bi_bytes_free":0,"bi_extents":0,"bi_cluster_hwm":0,"bi_current_cluster":0,"ai_log_size_gb":0,"ai_extents":0,"ai_current_extent":0},"memory":{"lru_scans_per_sec":0,"lock_table_current":0,"buffer_pool_current":0},"transactions":{"tps":0,"active_transactions":0,"long_transactions_over_60s":0,"longest_transaction_age_sec":0,"bi_cluster_avg_size_kb":0,"commits_total":0,"undos_total":0,"transactions_total":0},"locks":{"lock_waits_per_sec":0,"active_record_locks":0,"lock_waits_total":0},"connections":{"active_connections":0,"self_connections":0,"remote_connections":0,"batch_connections":0,"biw_process":0,"aiw_process":0,"wdog_process":0,"apw_process":0},"services":{"database_online":false},"configuration":{"db_create_date":"unknown","db_last_open_date":"unknown"},"license":{"lic_valid_users":0,"lic_current_connections":0,"lic_usage_percent":0,"lic_max_current":0},"storage":{"db_size_total_gb":0,"db_size_used_gb":0,"db_free_reusable_gb":0,"db_empty_unformatted_gb":0,"pct_free_reusable":0,"pct_consumed_hwm":0,"blocks_in_use":0,"total_blocks":0,"hi_water_mark":0,"most_locks_ever":0,"bi_size_gb":0,"pct_buffer_alloc":0,"pct_buffer_B2_alloc":0,"buffer_alloc_gb":0,"buffer_B2_alloc_gb":0,"large_files_enabled":false,"64bit_dbkeys_enabled":false,"large_keys_enabled":false,"64bit_sequences_enabled":false,"encryption_enabled":false,"auditing_enabled":false,"replication_enabled":false,"multitenancy_enabled":false,"cdc_enabled":false,"areas_at_risk_count":0,"areas_at_risk_names":"none","areas_with_fixed_last_extent":0,"areas_with_variable_last_extent":0},"backup":{"last_full_backup_date":"unknown","last_incr_backup_date":"unknown","minutes_since_full_backup":0,"minutes_since_incr_backup":0,"minutes_since_any_backup":0,"last_backup_type":"unknown"},"servers":{"total_brokers":0,"total_servers":0,"servers_4gl":0,"servers_sql":0,"users_4gl_current":0,"users_sql_current":0,"users_4gl_max":0,"users_sql_max":0,"total_pending_connections":0,"srv_bytes_received":0,"srv_bytes_sent":0,"srv_queries_received":0}},"errors":[{"metric":"database","message":"${_reason}","source":"openedgezbx_collector.sh","severity":"error"}]}
OFFJSON
}

# === DETECÇÃO DE MODO ========================================================

# Argumento "setup" força reconfiguração
if [ "$1" = "setup" ]; then
    rm -f "$ENV_FILE"
    run_setup
    echo "[INFO] Setup concluído. Execute novamente sem 'setup' para coletar."
    exit 0
fi

# Se o .env não existe, executa setup automaticamente
if [ ! -f "$ENV_FILE" ]; then
    run_setup
fi

# === CARREGA CONFIGURAÇÕES DO .ENV ===========================================

# shellcheck source=/dev/null
source "$ENV_FILE"

# Valida DLC carregado do .env
if [ -z "$DLC" ] || [ ! -d "$DLC" ]; then
    echo "[ERRO] DLC inválido no arquivo de configuração: '$DLC'"
    echo "       Execute: $0 setup"
    exit 1
fi

# === CONFIGURAÇÕES DERIVADAS =================================================

# Executáveis Progress
# O comando para listar bancos carregados é: proutil -C dbipcs
PROUTIL="$DLC/bin/proutil"
PROGRES="$DLC/bin/mpro"

# Programa coletor: usa .r se disponivel, senao .p.
# A partir da v1.3.2 o programa qualifica todas as VSTs com DICTDB.
# e cria o alias dinamicamente em runtime via LDBNAME(1). Isso torna
# o .r INDEPENDENTE do banco de compilacao — pode ser compilado uma
# vez contra qualquer banco e reusado em qualquer outro.
if [ -f "$SCRIPT_DIR/openedgezbx.r" ]; then
    PROG_FILE="$SCRIPT_DIR/openedgezbx.r"
else
    PROG_FILE="$SCRIPT_DIR/openedgezbx.p"
fi

# Monta PROPATH se configurado
PROPATH_CMD=""
if [ -n "$PROPATH_EXTRA" ]; then
    PROPATH_CMD="-pf $PROPATH_EXTRA"
fi

# Monta parâmetros de credenciais se configurados
AUTH_PARAMS=""
if [ -n "$DB_USER" ]; then
    AUTH_PARAMS="-U $DB_USER"
    if [ -n "$DB_PASS" ]; then
        AUTH_PARAMS="$AUTH_PARAMS -P $DB_PASS"
    fi
fi

# Modo debug: passa -param "debug=true" para o openedgezbx.p
DEBUG_PARAM=""
if [ "$1" = "debug" ]; then
    DEBUG_PARAM="-param debug=true"
    echo "[INFO] Modo debug ativado — JSON incluirá metadados completos"
fi

# Data/hora de execução
EXEC_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# === VALIDAÇÕES ==============================================================

if [ ! -x "$PROGRES" ]; then
    echo "[ERRO] Executável _progres não encontrado: $PROGRES"
    echo "       Verifique o DLC no arquivo: $ENV_FILE"
    exit 1
fi

if [ ! -x "$PROUTIL" ]; then
    echo "[ERRO] Utilitário proutil não encontrado: $PROUTIL"
    exit 1
fi

if [ ! -f "$PROG_FILE" ]; then
    echo "[ERRO] Programa coletor não encontrado: $PROG_FILE"
    exit 1
fi

# === CRIAÇÃO DO DIRETÓRIO DE SAÍDA ===========================================

mkdir -p "$JSON_DIR" 2>/dev/null
if [ ! -d "$JSON_DIR" ]; then
    echo "[ERRO] Não foi possível criar o diretório de saída: $JSON_DIR"
    exit 1
fi

# === COLETA DA LISTA DE BANCOS VIA DBIPCS ====================================

echo "============================================================"
echo "  openedgezbx — Coleta automatizada de métricas"
echo "  Início: $EXEC_DATE"
echo "  Config: $ENV_FILE"
echo "  DLC:    $DLC"
echo "  Saída:  $JSON_DIR"
if [ -n "$INCLUDE_DIRS" ]; then
echo "  Include: $INCLUDE_DIRS"
fi
if [ -n "$EXCLUDE_DIRS" ]; then
echo "  Exclude: $EXCLUDE_DIRS"
fi
echo "============================================================"
echo ""
echo "[INFO] Executando proutil -C dbipcs para listar bancos carregados..."

# Captura a saída de "proutil -C dbipcs" filtrando apenas linhas
# com "Yes" (bancos efetivamente carregados em shared memory).
# Formato da linha:
#   4  6414132    0 Yes   /producao/bancos/emsfnd.db
# O caminho do banco é o ÚLTIMO campo ($NF). Removemos a extensão .db
DB_LIST=$("$PROUTIL" -C dbipcs 2>/dev/null \
    | grep -i "Yes" \
    | awk '{print $NF}' \
    | sed 's/\.db$//' \
    | sort -u)

# === FUNÇÃO: aplica filtros INCLUDE_DIRS / EXCLUDE_DIRS a um caminho =========
#  Retorna 0 (true) se o banco PASSA pelos filtros, 1 (false) se DEVE ser
#  ignorado. Usado tanto na coleta normal quanto no loop de bancos offline
#  para garantir que filtros sao aplicados em TODOS os caminhos.
# =============================================================================
db_passes_filters() {
    local _path="$1"
    local _dir
    _dir=$(dirname "$_path")

    # EXCLUDE tem prioridade absoluta
    if [ -n "$EXCLUDE_DIRS" ]; then
        local _e
        IFS=',' read -ra _EXCL_ARR <<< "$EXCLUDE_DIRS"
        for _e in "${_EXCL_ARR[@]}"; do
            _e=$(echo "$_e" | sed 's:/*$::')
            if [ "$_dir" = "$_e" ] || [[ "$_dir" == "$_e"/* ]]; then
                return 1
            fi
        done
    fi

    # INCLUDE: se preenchido, banco DEVE estar em um dos diretorios
    if [ -n "$INCLUDE_DIRS" ]; then
        local _i
        IFS=',' read -ra _INCL_ARR <<< "$INCLUDE_DIRS"
        for _i in "${_INCL_ARR[@]}"; do
            _i=$(echo "$_i" | sed 's:/*$::')
            if [ "$_dir" = "$_i" ] || [[ "$_dir" == "$_i"/* ]]; then
                return 0
            fi
        done
        # Nao casou com nenhum INCLUDE — rejeita
        return 1
    fi

    # Sem INCLUDE e nao caiu em EXCLUDE — aceita
    return 0
}

# === INVENTÁRIO: rastreia bancos conhecidos ================================
#  O arquivo .inventory armazena a lista de bancos já coletados.
#  Quando um banco desaparece do dbipcs (offline), geramos JSON offline
#  para que o Zabbix dispare o trigger Database OFFLINE imediatamente.
# ===========================================================================
INVENTORY_FILE="$SCRIPT_DIR/.openedgezbx_inventory"

# Aplica filtros INCLUDE/EXCLUDE ao DB_LIST atual antes de qualquer coisa.
# Bancos filtrados nao entram no inventario nem na coleta.
DB_LIST_FILTERED=""
if [ -n "$DB_LIST" ]; then
    while IFS= read -r _dbpath; do
        [ -z "$_dbpath" ] && continue
        if db_passes_filters "$_dbpath"; then
            DB_LIST_FILTERED="${DB_LIST_FILTERED}${_dbpath}
"
        fi
    done <<< "$DB_LIST"
    # Remove trailing newline e linhas vazias
    DB_LIST_FILTERED=$(echo "$DB_LIST_FILTERED" | grep -v "^$" | sort -u)
fi

# Atualiza inventário com bancos atualmente online (apos filtros).
# Tambem aplica filtros ao inventario antigo, removendo entradas que
# nao casam mais com a configuracao atual de INCLUDE/EXCLUDE.
if [ -n "$DB_LIST_FILTERED" ]; then
    if [ -f "$INVENTORY_FILE" ]; then
        # Filtra inventario antigo aplicando os mesmos criterios
        FILTERED_KNOWN=""
        while IFS= read -r _knowndb; do
            [ -z "$_knowndb" ] && continue
            if db_passes_filters "$_knowndb"; then
                FILTERED_KNOWN="${FILTERED_KNOWN}${_knowndb}
"
            fi
        done < "$INVENTORY_FILE"
        FILTERED_KNOWN=$(echo "$FILTERED_KNOWN" | grep -v "^$" | sort -u)
        ALL_DBS=$(echo -e "${DB_LIST_FILTERED}\n${FILTERED_KNOWN}" | grep -v "^$" | sort -u)
    else
        ALL_DBS="$DB_LIST_FILTERED"
    fi
    echo "$ALL_DBS" > "$INVENTORY_FILE"
    # Substitui DB_LIST pela versao filtrada (usado no loop de coleta)
    DB_LIST="$DB_LIST_FILTERED"
else
    # Nenhum banco online (ou todos filtrados) — usa inventario filtrado
    DB_LIST=""
    if [ -f "$INVENTORY_FILE" ]; then
        FILTERED_KNOWN=""
        while IFS= read -r _knowndb; do
            [ -z "$_knowndb" ] && continue
            if db_passes_filters "$_knowndb"; then
                FILTERED_KNOWN="${FILTERED_KNOWN}${_knowndb}
"
            fi
        done < "$INVENTORY_FILE"
        FILTERED_KNOWN=$(echo "$FILTERED_KNOWN" | grep -v "^$" | sort -u)
        if [ -n "$FILTERED_KNOWN" ]; then
            echo "$FILTERED_KNOWN" > "$INVENTORY_FILE"
            ALL_DBS="$FILTERED_KNOWN"
        else
            # Inventario inteiro foi filtrado — limpa o arquivo
            > "$INVENTORY_FILE"
            ALL_DBS=""
        fi
    else
        echo "[AVISO] Nenhum banco apos filtros e nenhum inventario anterior."
        echo "        Verifique INCLUDE_DIRS / EXCLUDE_DIRS no .env."
        exit 0
    fi
fi

# Identifica bancos que saíram do ar (estão no inventário mas não no dbipcs)
OFFLINE_DBS=""
if [ -f "$INVENTORY_FILE" ]; then
    while read -r KNOWN_DB; do
        [ -z "$KNOWN_DB" ] && continue
        if ! echo "$DB_LIST" | grep -qxF "$KNOWN_DB"; then
            OFFLINE_DBS="${OFFLINE_DBS}${KNOWN_DB}
"
        fi
    done < "$INVENTORY_FILE"
fi

if [ -z "$DB_LIST" ]; then
    echo "[AVISO] Nenhum banco online apos filtros INCLUDE/EXCLUDE."
    DB_TOTAL=0
else
    DB_TOTAL=$(echo "$DB_LIST" | wc -l)
fi
echo "[INFO] $DB_TOTAL banco(s) online (apos filtros) para coletar."

SUCCESS=0
FAIL=0

if [ -n "$DB_LIST" ]; then
    DB_COUNT=$(echo "$DB_LIST" | wc -l)
    echo ""
    echo "[INFO] $DB_COUNT banco(s) online após filtro de diretórios:"
    echo "$DB_LIST" | while read -r DBPATH; do
        echo "        - $DBPATH"
    done
    echo ""
else
    DB_COUNT=0
fi

# === COLETA DE MÉTRICAS POR BANCO (somente online) ==========================

if [ -n "$DB_LIST" ]; then
echo "$DB_LIST" | while read -r DBPATH; do

    # Extrai o nome lógico do banco a partir do caminho
    DBNAME=$(basename "$DBPATH")

    # Nome do arquivo: caminho completo com / substituído por _
    # Exemplo: /producao/bancos/emsfnd -> producao_bancos_emsfnd.json
    OUTNAME=$(echo "$DBPATH" | sed 's:^/::' | tr '/' '_')
    OUTFILE="$JSON_DIR/${OUTNAME}.json"

    echo -n "[....] Coletando $DBNAME ($DBPATH) ... "

    # Monta o comando completo de execução.
    # Captura saida bruta + stderr em arquivo temp para diagnostico
    # quando mpro falha (banco "online" no dbipcs mas mpro nao conecta).
    RAW_OUT="$JSON_DIR/.${OUTNAME}.raw"
    "$PROGRES" -db "$DBPATH" -ld "$DBNAME" -b -q \
        $AUTH_PARAMS $EXTRA_PARAMS $DEBUG_PARAM \
        -p "$PROG_FILE" \
        > "$RAW_OUT" 2>&1

    # Filtra apenas linhas JSON (comecam com {)
    grep "^{" "$RAW_OUT" > "$OUTFILE"

    # Valida o JSON gerado
    if [ -s "$OUTFILE" ]; then
        FIRST_CHAR=$(head -c1 "$OUTFILE")
        LAST_CHAR=$(tail -c2 "$OUTFILE" | head -c1)
        if [ "$FIRST_CHAR" = "{" ] && [ "$LAST_CHAR" = "}" ]; then
            SIZE=$(wc -c < "$OUTFILE" | tr -d ' ')
            echo -e "\r[ OK ] Coletando $DBNAME -> $OUTFILE ($SIZE bytes)"
            SUCCESS=$((SUCCESS + 1))
            rm -f "$RAW_OUT"
        else
            echo -e "\r[WARN] Coletando $DBNAME -> JSON possivelmente invalido"
            echo "       Saida bruta em: $RAW_OUT"
        fi
    else
        # ============================================================
        # BANCO OFFLINE: gera JSON completo (todas as chaves esperadas
        # pelo template Zabbix v1.3.1+) para que o Zabbix detecte via
        # trigger "Database OFFLINE" (database_online = false) sem erros
        # de JSONPath em chaves ausentes.
        # ============================================================
        # Captura ultima linha de erro do mpro para diagnostico
        ERR_MSG=$(grep -v "^$" "$RAW_OUT" | grep -iE "error|fail|nao|denied|invalid|^\*\*" | tail -1 | tr -d '"' | cut -c1-200)
        [ -z "$ERR_MSG" ] = ERR_MSG="mpro falhou - ver $RAW_OUT"

        gen_offline_json "$DBNAME" "$DBPATH" "$OUTFILE" \
            "Banco offline ou inacessivel - mpro: ${ERR_MSG}"
        echo -e "\r[DOWN] Coletando $DBNAME -> $OUTFILE (OFFLINE)"
        echo "       Erro mpro: $ERR_MSG"
        echo "       Saida bruta preservada em: $RAW_OUT"
        FAIL=$((FAIL + 1))
    fi

done
fi  # if [ -n "$DB_LIST" ]

# === BANCOS OFFLINE: gera JSON para bancos que sumiram do dbipcs ============
#  Bancos que estavam no inventário mas não apareceram no dbipcs atual
#  são considerados offline. Geramos JSON mínimo com database_online=false
#  para que o Zabbix dispare o trigger Database OFFLINE imediatamente.
# ===========================================================================

if [ -n "$OFFLINE_DBS" ]; then
    echo ""
    echo "[WARN] Bancos OFFLINE detectados (nao estao no dbipcs):"
    echo "$OFFLINE_DBS" | while read -r OFFPATH; do
        [ -z "$OFFPATH" ] && continue

        # Aplica filtros INCLUDE/EXCLUDE tambem aos bancos offline.
        # Sem isso, bancos de diretorios excluidos que ja estavam no
        # inventario continuariam gerando JSON offline indevidamente.
        if ! db_passes_filters "$OFFPATH"; then
            echo "  [SKIP] $OFFPATH (filtrado por INCLUDE/EXCLUDE)"
            continue
        fi

        OFFNAME=$(basename "$OFFPATH")
        OFFOUTNAME=$(echo "$OFFPATH" | sed 's:^/::' | tr '/' '_')
        OFFOUTFILE="$JSON_DIR/${OFFOUTNAME}.json"

        gen_offline_json "$OFFNAME" "$OFFPATH" "$OFFOUTFILE" \
            "Banco offline - nao encontrado no dbipcs"

        echo "  [DOWN] $OFFNAME ($OFFPATH) -> $OFFOUTFILE"
        FAIL=$((FAIL + 1))
    done
fi

# === LIMPEZA: remove JSONs de bancos que nao casam mais com os filtros =====
# Apos mudar INCLUDE_DIRS/EXCLUDE_DIRS, JSONs antigos podem permanecer no
# diretorio e continuar sendo lidos pelo Zabbix. Lemos o physical_path do
# proprio JSON para verificar se passa pelos filtros atuais.
if [ -d "$JSON_DIR" ]; then
    for _jsonfile in "$JSON_DIR"/*.json; do
        [ -f "$_jsonfile" ] || continue
        # Extrai physical_path do JSON (primeiro match)
        _phys=$(grep -o '"physical_path":"[^"]*"' "$_jsonfile" 2>/dev/null \
                | head -1 \
                | sed 's/"physical_path":"//; s/"$//')
        [ -z "$_phys" ] && continue
        if ! db_passes_filters "$_phys"; then
            echo "  [CLEAN] Removendo JSON orfao filtrado: $(basename "$_jsonfile") ($_phys)"
            rm -f "$_jsonfile"
        fi
    done
fi

# === RESUMO ==================================================================

echo ""
echo "============================================================"
echo "  Coleta finalizada: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Diretório de saída: $JSON_DIR"
echo "============================================================"
echo ""

ls -lh "$JSON_DIR"/*.json 2>/dev/null

exit 0
