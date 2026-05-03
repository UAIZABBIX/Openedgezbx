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

# Programa coletor — usa .r (compilado) se existir, senão .p (fonte)
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

# === INVENTÁRIO: rastreia bancos conhecidos ================================
#  O arquivo .inventory armazena a lista de bancos já coletados.
#  Quando um banco desaparece do dbipcs (offline), geramos JSON offline
#  para que o Zabbix dispare o trigger Database OFFLINE imediatamente.
# ===========================================================================
INVENTORY_FILE="$SCRIPT_DIR/.openedgezbx_inventory"

# Atualiza inventário com bancos atualmente online
if [ -n "$DB_LIST" ]; then
    # Merge: bancos atuais + inventário anterior (sem duplicatas)
    if [ -f "$INVENTORY_FILE" ]; then
        KNOWN_DBS=$(cat "$INVENTORY_FILE" | sort -u)
        ALL_DBS=$(echo -e "${DB_LIST}\n${KNOWN_DBS}" | sort -u)
    else
        ALL_DBS="$DB_LIST"
    fi
    # Salva inventário atualizado
    echo "$ALL_DBS" > "$INVENTORY_FILE"
else
    # Nenhum banco online — usa inventário anterior se existir
    if [ -f "$INVENTORY_FILE" ]; then
        ALL_DBS=$(cat "$INVENTORY_FILE" | sort -u)
    else
        echo "[AVISO] Nenhum banco encontrado e nenhum inventário anterior."
        echo "        Verifique se há bancos rodando neste servidor."
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
    echo "[AVISO] Nenhum banco online encontrado via dbipcs."
    DB_TOTAL=0
else
    DB_TOTAL=$(echo "$DB_LIST" | wc -l)
fi
echo "[INFO] $DB_TOTAL banco(s) online encontrado(s) no dbipcs."

# === FILTRO DE DIRETÓRIOS =====================================================
#  INCLUDE_DIRS: se preenchido, mantém SOMENTE bancos cujo diretório
#                corresponde a um dos caminhos da lista.
#  EXCLUDE_DIRS: remove bancos cujo diretório corresponde a um dos
#                caminhos da lista (tem prioridade sobre include).
#  A comparação verifica se o diretório do banco COMEÇA com o filtro,
#  permitindo que /producao/bancos capture /producao/bancos/subdir/db.
# =============================================================================

DB_FILTERED=""

echo "$DB_LIST" | while read -r DBPATH; do
    # Diretório onde o banco reside
    DBDIR=$(dirname "$DBPATH")

    # --- Verifica EXCLUDE primeiro (prioridade) ---
    if [ -n "$EXCLUDE_DIRS" ]; then
        EXCLUDED=false
        IFS=',' read -ra EXCL_ARR <<< "$EXCLUDE_DIRS"
        for EXCL in "${EXCL_ARR[@]}"; do
            EXCL=$(echo "$EXCL" | sed 's:/*$::')  # remove / final
            if [ "$DBDIR" = "$EXCL" ] || [[ "$DBDIR" == "$EXCL"/* ]]; then
                EXCLUDED=true
                break
            fi
        done
        if [ "$EXCLUDED" = true ]; then
            echo "[SKIP] $DBPATH (diretório excluído: $EXCL)"
            continue
        fi
    fi

    # --- Verifica INCLUDE (se configurado) ---
    if [ -n "$INCLUDE_DIRS" ]; then
        INCLUDED=false
        IFS=',' read -ra INCL_ARR <<< "$INCLUDE_DIRS"
        for INCL in "${INCL_ARR[@]}"; do
            INCL=$(echo "$INCL" | sed 's:/*$::')  # remove / final
            if [ "$DBDIR" = "$INCL" ] || [[ "$DBDIR" == "$INCL"/* ]]; then
                INCLUDED=true
                break
            fi
        done
        if [ "$INCLUDED" = false ]; then
            echo "[SKIP] $DBPATH (diretório não está nos permitidos)"
            continue
        fi
    fi

    # Banco aprovado pelos filtros
    echo "$DBPATH" >> "$JSON_DIR/.db_filtered.tmp"
done

# Lê a lista filtrada do arquivo temporário
if [ -f "$JSON_DIR/.db_filtered.tmp" ]; then
    DB_FILTERED=$(cat "$JSON_DIR/.db_filtered.tmp")
    rm -f "$JSON_DIR/.db_filtered.tmp"
fi

if [ -z "$DB_FILTERED" ]; then
    echo ""
    if [ -z "$OFFLINE_DBS" ]; then
        echo "[AVISO] Nenhum banco restou após aplicar os filtros de diretório."
        echo "        Verifique INCLUDE_DIRS e EXCLUDE_DIRS no arquivo:"
        echo "        $ENV_FILE"
    else
        echo "[AVISO] Nenhum banco online após filtros. Processando bancos offline..."
    fi
    DB_LIST=""
else
    # Substitui a lista original pela filtrada
    DB_LIST="$DB_FILTERED"
fi

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

    # Monta o comando completo de execução
    # - Conecta via shared memory (banco local carregado)
    # - -ld define o nome lógico
    # - -b batch, -q quiet
    # - AUTH_PARAMS: credenciais (se configuradas)
    # - EXTRA_PARAMS: parâmetros extras do .env
    # - DEBUG_PARAM: modo debug (se ativado)
    # - 2>/dev/null descarta stderr
    # - grep "^{" filtra apenas a linha JSON
    "$PROGRES" -db "$DBPATH" -ld "$DBNAME" -b -q \
        $AUTH_PARAMS $EXTRA_PARAMS $DEBUG_PARAM \
        -p "$PROG_FILE" \
        2>/dev/null | grep "^{" > "$OUTFILE"

    # Valida o JSON gerado
    if [ -s "$OUTFILE" ]; then
        FIRST_CHAR=$(head -c1 "$OUTFILE")
        LAST_CHAR=$(tail -c2 "$OUTFILE" | head -c1)
        if [ "$FIRST_CHAR" = "{" ] && [ "$LAST_CHAR" = "}" ]; then
            SIZE=$(wc -c < "$OUTFILE" | tr -d ' ')
            echo -e "\r[ OK ] Coletando $DBNAME -> $OUTFILE ($SIZE bytes)"
            SUCCESS=$((SUCCESS + 1))
        else
            echo -e "\r[WARN] Coletando $DBNAME -> JSON possivelmente inválido"
        fi
    else
        # ============================================================
        # BANCO OFFLINE: gera JSON mínimo para que o Zabbix detecte
        # via trigger "Database OFFLINE" (database_online = false).
        # Sem este JSON, o Zabbix só detectaria via "no data" (10min).
        # ============================================================
        NOW_ISO=$(date '+%Y-%m-%dT%H:%M:%S')
        HOSTNAME_LOCAL=$(hostname 2>/dev/null || echo "unknown")
        cat > "$OUTFILE" << OFFJSON
{"collector":{"name":"openedgezbx","version":"1.2.0","language":"Progress ABL","generated_at":"${NOW_ISO}","status":"error"},"database":{"logical_name":"${DBNAME}","physical_name":"${DBPATH}","physical_path":"${DBPATH}","host":"${HOSTNAME_LOCAL}","openedge_version":"unknown","db_status":"offline","pid":0,"uptime_seconds":0,"active_connections":0,"notes":"Banco offline ou inacessível — coleta via mpro falhou"},"summary":{"health_status":"critical","error_count":1,"warning_count":0},"metrics":{"io":{"buffer_hit_ratio":null},"memory":{},"transactions":{"tps":0,"active_transactions":0},"locks":{"lock_waits_per_sec":0,"active_record_locks":0},"connections":{"active_connections":0,"self_connections":0,"remote_connections":0,"batch_connections":0,"biw_process":0,"aiw_process":0,"wdog_process":0,"apw_process":0},"services":{"database_online":false},"configuration":{},"license":{},"servers":{"total_brokers":0,"total_servers":0,"servers_4gl":0,"servers_sql":0}},"errors":[{"metric":"database","message":"Banco offline ou inacessível","source":"openedgezbx_collector.sh","severity":"error"}]}
OFFJSON
        echo -e "\r[DOWN] Coletando $DBNAME -> $OUTFILE (OFFLINE)"
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
    echo "[WARN] Bancos OFFLINE detectados (não estão no dbipcs):"
    echo "$OFFLINE_DBS" | while read -r OFFPATH; do
        [ -z "$OFFPATH" ] && continue
        OFFNAME=$(basename "$OFFPATH")
        OFFOUTNAME=$(echo "$OFFPATH" | sed 's:^/::' | tr '/' '_')
        OFFOUTFILE="$JSON_DIR/${OFFOUTNAME}.json"
        NOW_ISO=$(date '+%Y-%m-%dT%H:%M:%S')
        HOSTNAME_LOCAL=$(hostname 2>/dev/null || echo "unknown")

        cat > "$OFFOUTFILE" << OFFJSON
{"collector":{"name":"openedgezbx","version":"1.0.0","language":"Progress ABL","generated_at":"${NOW_ISO}","status":"error"},"database":{"logical_name":"${OFFNAME}","physical_name":"${OFFPATH}","physical_path":"${OFFPATH}","host":"${HOSTNAME_LOCAL}","openedge_version":"unknown","db_status":"offline","pid":0,"uptime_seconds":0,"active_connections":0,"notes":"Banco offline — não encontrado no dbipcs"},"summary":{"health_status":"critical","error_count":1,"warning_count":0},"metrics":{"io":{"buffer_hit_ratio":0,"physical_reads_per_sec":0,"physical_writes_per_sec":0},"memory":{"lock_table_current":0},"transactions":{"tps":0,"active_transactions":0,"long_transactions_over_60s":0},"locks":{"lock_waits_per_sec":0,"active_record_locks":0},"connections":{"active_connections":0,"self_connections":0,"remote_connections":0,"batch_connections":0,"biw_process":0,"aiw_process":0,"wdog_process":0,"apw_process":0},"services":{"database_online":false},"configuration":{},"license":{"lic_valid_users":0,"lic_current_connections":0,"lic_usage_percent":0},"servers":{"total_brokers":0,"total_servers":0,"servers_4gl":0,"servers_sql":0,"users_4gl_current":0,"users_sql_current":0},"storage":{"db_size_total_gb":0,"db_size_used_gb":0,"pct_free_reusable":0,"pct_consumed_hwm":0,"large_files_enabled":false,"areas_at_risk_count":0},"backup":{}},"errors":[{"metric":"database","message":"Banco offline — não encontrado no dbipcs","source":"openedgezbx_collector.sh","severity":"error"}]}
OFFJSON

        echo "  [DOWN] $OFFNAME ($OFFPATH) -> $OFFOUTFILE"
        FAIL=$((FAIL + 1))
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
