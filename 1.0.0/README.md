# openedgezbx

Sistema completo de monitoracao de bancos **Progress OpenEdge RDBMS** para **Zabbix**, composto por:

1. **Coletor ABL** (`openedgezbx.p`) — programa Progress 4GL/ABL que consulta VSTs e emite JSON estruturado via STDOUT
2. **Shell collector** (`openedgezbx_collector.sh`) — automacao de coleta com autodescoberta de bancos carregados, incluindo JSON minimo para bancos offline
3. **Templates Zabbix 7.0** — autodiscovery, 104 item prototypes, 34 graph prototypes, 19 trigger prototypes

**Versao:** 1.0.0 — validado em producao no servidor `openedgerdbms001` (Linux), OpenEdge 12.2 e 12.8, Zabbix 7.0.25.

---

## Sumario

- [Arquitetura](#arquitetura)
- [Arquivos do projeto](#arquivos-do-projeto)
- [Requisitos](#requisitos)
- [Instalacao](#instalacao)
- [Coletor ABL](#coletor-abl)
- [Shell Collector](#shell-collector)
- [Inventario Offline — Deteccao de bancos down](#inventario-offline--deteccao-de-bancos-down)
- [Templates Zabbix](#templates-zabbix)
- [Configuracao do Agent2](#configuracao-do-agent2)
- [Autodiscovery e Graph Prototypes](#autodiscovery-e-graph-prototypes)
- [Modo Debug](#modo-debug)
- [Categorias de metricas](#categorias-de-metricas)
- [VSTs utilizadas](#vsts-utilizadas)
- [Limitacoes conhecidas](#limitacoes-conhecidas)
- [Manutencao e extensao](#manutencao-e-extensao)

---

## Arquitetura

```
[Cron 1min]
    |
    v
openedgezbx_collector.sh
    |
    +-- proutil -C dbipcs --> lista bancos carregados
    |
    +-- .openedgezbx_inventory --> compara bancos conhecidos vs dbipcs atual
    |       |
    |       +--> banco sumiu do dbipcs --> JSON offline (database_online=false)
    |
    +-- mpro -db <banco> -b -q -p openedgezbx.p
    |       |
    |       +--> JSON via STDOUT --> json_zbx/<banco>.json
    |       |
    |       +--> (falha mpro) --> JSON minimo com database_online=false
    |
    v
[Zabbix Agent2]
    |
    +-- vfs.dir.get --> Discovery dos JSONs (regex \.json$)
    |
    +-- vfs.file.contents --> Le cada JSON (master item)
    |
    +-- JSONPath preprocessing --> Extrai cada metrica (dependent items)
    |
    v
[Zabbix Server]
    |
    +-- Triggers, Graphs, Dashboards, Alertas
```

---

## Arquivos do projeto

| Arquivo | Descricao |
|---|---|
| `openedgezbx.p` | Coletor ABL v1.3.0 (programa Progress 4GL/ABL principal) — storage, backup, servers, features, license, processos servico, log file size |
| `openedgezbx_collector.sh` | Script shell de coleta automatizada com setup interativo, inventario offline e JSON offline |
| `openedgezbx_collector.env` | Arquivo de configuracao gerado pelo setup (DLC, credenciais, filtros) |
| `.openedgezbx_inventory` | Inventario de bancos conhecidos (gerado automaticamente pelo collector em runtime) |
| `emsfnd.pf` | Arquivo .pf de conexao remota TCP (exemplo) |
| `json_zbx/` | Diretorio de saida dos JSONs |
| `zabbix_templates/openedgezbx_passive.yaml` | Template Zabbix 7.0 passivo com autodiscovery |
| `zabbix_templates/openedgezbx_active.yaml` | Template Zabbix 7.0 ativo |
| `zabbix_templates/openedgezbx.conf` | Configuracao do Zabbix Agent2 |
| `AGENT2_SETUP.md` | Guia de configuracao do Agent2 |
| `CHANGELOG.md` | Registro de alteracoes por versao |
| `openedge_monitoring_reference_table.html` | Tabela de referencia de thresholds |

---

## Requisitos

| Item | Versao / Detalhe |
|---|---|
| Progress OpenEdge | 12.2+ (testado em 12.2 e 12.8) |
| Modo de execucao | Batch (`-b`) |
| Privilegio de banco | Acesso de leitura ao schema VST |
| SO | Linux (producao) / Windows (desenvolvimento) |
| Zabbix Server | 7.0+ |
| Zabbix Agent2 | Instalado no servidor do banco |

---

## Instalacao

### 1. Copiar arquivos para o servidor

```sh
# Criar diretorio
mkdir -p /openedgezbx/json_zbx

# Copiar arquivos do projeto
cp openedgezbx.p /openedgezbx/
cp openedgezbx_collector.sh /openedgezbx/
chmod +x /openedgezbx/openedgezbx_collector.sh
```

### 2. Configurar o shell collector (setup interativo)

```sh
/openedgezbx/openedgezbx_collector.sh --setup
```

O setup solicita:
- Caminho do DLC (`$DLC/bin`)
- Credenciais de conexao (usuario/senha)
- Filtros `INCLUDE_DIRS` (coletar apenas bancos em diretorios especificos)
- Filtros `EXCLUDE_DIRS` (ignorar bancos em diretorios especificos)

Gera o arquivo `openedgezbx_collector.env` com todas as configuracoes.

### 3. Agendar no cron

```sh
crontab -e
# Adicionar:
* * * * * /openedgezbx/openedgezbx_collector.sh >> /openedgezbx/collector.log 2>&1
```

### 4. Instalar templates no Zabbix

Ver secao [Configuracao do Agent2](#configuracao-do-agent2) e o guia completo em `AGENT2_SETUP.md`.

---

## Coletor ABL

### Execucao direta

```sh
# Linux — com caminho do banco
$DLC/bin/mpro /producao/bancos/emsfnd -ld emsfnd -b -q -p /openedgezbx/openedgezbx.p

# Linux — com arquivo .pf
$DLC/bin/_progres -pf /openedgezbx/emsfnd.pf -b -q -p /openedgezbx/openedgezbx.p

# Capturando JSON em variavel shell
JSON=$($DLC/bin/mpro /producao/bancos/emsfnd -ld emsfnd -b -q -p /openedgezbx/openedgezbx.p)
echo "$JSON" | python -m json.tool
```

### Estrutura do JSON de saida

```json
{
  "collector": {
    "name": "openedgezbx",
    "version": "1.0.0",
    "language": "Progress ABL",
    "generated_at": "YYYY-MM-DDTHH:MM:SS",
    "status": "ok | warning | error"
  },
  "database": {
    "logical_name": "...",
    "physical_name": "...",
    "physical_path": "...",
    "host": "...",
    "openedge_version": "...",
    "db_status": "online",
    "pid": 0,
    "uptime_seconds": 864213,
    "active_connections": 47,
    "notes": null
  },
  "summary": {
    "health_status": "healthy | warning | critical",
    "error_count": 0,
    "warning_count": 0
  },
  "metrics": {
    "io":            { "...": {"value": ..., "unit": "...", "status": "...", ...} },
    "memory":        { "..." },
    "transactions":  { "..." },
    "locks":         { "..." },
    "connections":   { "..." },
    "services":      { "..." },
    "configuration": { "..." },
    "license":       { "..." },
    "storage":       { "..." },
    "backup":        { "..." },
    "servers":       { "..." }
  },
  "errors": []
}
```

Cada metrica segue o esquema:
```json
{
  "value": "<number | string | boolean | null>",
  "unit": "<unidade>",
  "status": "healthy | warning | critical | unknown",
  "warning_threshold": "<faixa>",
  "critical_threshold": "<faixa>",
  "source": "<VST ou calculo>",
  "observation": "<nota ou null>"
}
```

---

## Shell Collector

O `openedgezbx_collector.sh` automatiza a coleta para todos os bancos carregados no servidor:

1. Carrega configuracoes do `.env`
2. Lista bancos via `$DLC/bin/proutil -C dbipcs | grep Yes | awk '{print $NF}'`
3. Aplica filtros INCLUDE_DIRS / EXCLUDE_DIRS
4. Executa `$DLC/bin/mpro -db <banco> -b -q -p openedgezbx.p` para cada banco
5. Grava JSON em `json_zbx/` com nome baseado no caminho (ex: `producao_bancos_emsfnd.json`)
6. **Se mpro falhar**, gera JSON minimo com `database_online=false` (permite trigger de banco offline no Zabbix)

### Filtros INCLUDE/EXCLUDE

No arquivo `.env`:
```sh
# Coletar APENAS bancos nestes diretorios
INCLUDE_DIRS="/producao/bancos,/homologacao/bancos"

# Ignorar bancos nestes diretorios
EXCLUDE_DIRS="/tmp,/backup"
```

### Nomenclatura dos JSONs

O caminho completo do banco tem `/` substituido por `_`:
- `/producao/bancos/emsfnd.db` -> `producao_bancos_emsfnd.json`
- `/homologacao/bancos/teste.db` -> `homologacao_bancos_teste.json`

---

## Inventario Offline -- Deteccao de bancos down

A partir da v1.3.1, o `openedgezbx_collector.sh` mantem um arquivo `.openedgezbx_inventory` no diretorio do script que rastreia todos os bancos ja vistos pelo sistema. Isso permite detectar automaticamente quando um banco sai do ar (desaparece do `proutil -C dbipcs`).

### Como funciona

1. **1a execucao:** `dbipcs` encontra bancos carregados -> salva no inventario -> coleta normal
2. **Banco cai:** `dbipcs` nao lista mais o banco -> inventario lembra que ele existia -> gera JSON minimo com `database_online: false` e `db_status: "offline"`
3. **Banco volta:** `dbipcs` encontra novamente -> coleta normal sobrescreve o JSON -> trigger resolve automaticamente

### Trigger "Database OFFLINE"

- Severidade: **Disaster** (nivel maximo no Zabbix)
- Dispara imediatamente quando `database_online` muda para `false`
- Resolve automaticamente quando o banco volta e a coleta normal gera `database_online: true`

### JSON offline gerado

Quando um banco e detectado como offline, o collector gera um JSON com:
- `database_online: false`
- `db_status: "offline"`
- Todas as secoes de metricas presentes com valores zerados (0/false)
- Estrutura JSON completa para evitar erros de JSONPath no Zabbix

### Arquivo de inventario

O arquivo `.openedgezbx_inventory` e criado automaticamente no diretorio do script. Contem um caminho de banco por linha. Nao deve ser editado manualmente em operacao normal.

---

## Templates Zabbix

### Modos disponiveis

| Template | Modo | Quando usar |
|---|---|---|
| `openedgezbx_passive.yaml` | Passivo | Agent acessivel pelo Server via rede (porta 10050) |
| `openedgezbx_active.yaml` | Ativo | Agent atras de firewall/NAT, ou muitos hosts |

### Importacao

1. Acesse **Configuration > Templates > Import** no frontend Zabbix
2. Selecione o arquivo YAML desejado
3. Marque **Create new** e **Update existing**
4. Clique em **Import**

### Vincular ao host

1. **Configuration > Hosts** > selecione o servidor OpenEdge
2. Em **Templates**, adicione `OpenEdge RDBMS - Passive` ou `OpenEdge RDBMS - Active`
3. Ajuste a macro `{$OZBX_JSON_DIR}` se o diretorio for diferente de `/openedgezbx/json_zbx`

---

## Configuracao do Agent2

### Arquivo de configuracao

Copie `zabbix_templates/openedgezbx.conf` para o diretorio de configuracao do Agent2:

```sh
cp zabbix_templates/openedgezbx.conf /etc/zabbix/zabbix_agent2.d/
```

### Parametros criticos

```ini
# OBRIGATORIO — DenyKey junto com AllowKey
DenyKey=system.run[*]
AllowKey=vfs.file.contents[/openedgezbx/json_zbx/*]
AllowKey=vfs.dir.get[/openedgezbx/json_zbx,*]
```

### Permissoes

```sh
# O usuario do agent2 (zabbix) precisa ler os JSONs
chmod 644 /openedgezbx/json_zbx/*.json
# Ou adicionar ao grupo
usermod -aG <grupo_progress> zabbix
```

### Reiniciar

```sh
systemctl restart zabbix-agent2
systemctl status zabbix-agent2
```

Guia completo em `AGENT2_SETUP.md`.

---

## Autodiscovery e Graph Prototypes

### Como funciona o discovery

1. O template usa `vfs.dir.get[{$OZBX_JSON_DIR}]` como discovery rule
2. Filtro por regex: `{#FILENAME}` matches `\.json$`
3. Macro LLD: `{#PATHNAME}` (caminho absoluto do arquivo JSON)
4. Para cada JSON descoberto, cria automaticamente todos os items, graphs e triggers

### Graph prototypes (34 por banco)

Os templates incluem 34 graph prototypes autodescobertos por banco, cobrindo:
- Buffer hit ratio ao longo do tempo
- Physical reads/writes por segundo
- TPS (transacoes por segundo)
- Lock waits por segundo
- Conexoes ativas
- Transacoes longas
- BI/AI log usage
- License Usage (Current vs Licensed)
- License Usage (%)
- Service Processes (BIW/AIW/WDOG/APW stacked)
- Log File Size (MB)
- Storage: tamanho total/usado/livre em GB
- Storage: % consumido ate HWM e % livre reutilizavel
- Storage: buffer -B/-B1 alocacao e memoria
- Backup: minutos desde ultimo full/incremental
- Servers: contagem 4GL vs SQL, atividade
- Areas at risk
- E outros indicadores de performance

### Trigger prototypes (19 por banco)

| Trigger | Severidade |
|---|---|
| Database OFFLINE | Disaster |
| Buffer hit ratio < critical | High |
| Buffer hit ratio < warning | Warning |
| Long transactions >= critical | High |
| Long transactions >= warning | Warning |
| Lock waits/sec > critical | High |
| Lock waits/sec > warning | Warning |
| Physical reads/sec > critical | High |
| % consumido ate HWM >= critical | High |
| % consumido ate HWM >= warning | Warning |
| % livre reutilizavel <= critical | High |
| % livre reutilizavel <= warning | Warning |
| Full backup atrasado >= critical | High |
| Full backup atrasado >= warning | Warning |
| Qualquer backup atrasado >= critical | High |
| Qualquer backup atrasado >= warning | Warning |
| Areas at risk > 0 | Warning |
| License usage >= 90% | Warning |
| No data for 10 minutes | Warning |

### Macros ajustaveis (thresholds)

| Macro | Padrao | Descricao |
|---|---|---|
| `{$OZBX_JSON_DIR}` | `/openedgezbx/json_zbx` | Diretorio dos JSONs |
| `{$OZBX_BUFFER_HIT_WARN}` | `95` | Buffer hit ratio warning (%) |
| `{$OZBX_BUFFER_HIT_CRIT}` | `90` | Buffer hit ratio critical (%) |
| `{$OZBX_LONG_TRANS_WARN}` | `1` | Transacoes longas warning |
| `{$OZBX_LONG_TRANS_CRIT}` | `3` | Transacoes longas critical |
| `{$OZBX_LOCK_WAITS_WARN}` | `1` | Lock waits/sec warning |
| `{$OZBX_LOCK_WAITS_CRIT}` | `10` | Lock waits/sec critical |
| `{$OZBX_READS_SEC_WARN}` | `50` | Physical reads/sec warning |
| `{$OZBX_READS_SEC_CRIT}` | `200` | Physical reads/sec critical |
| `{$OZBX_CONSUMED_HWM_WARN}` | `90` | % consumido ate HWM warning |
| `{$OZBX_CONSUMED_HWM_CRIT}` | `95` | % consumido ate HWM critical |
| `{$OZBX_FREE_REUSE_WARN}` | `10` | % livre reutilizavel warning |
| `{$OZBX_FREE_REUSE_CRIT}` | `5` | % livre reutilizavel critical |
| `{$OZBX_BACKUP_FULL_WARN}` | `1440` | Minutos sem full backup warning (24h) |
| `{$OZBX_BACKUP_FULL_CRIT}` | `2880` | Minutos sem full backup critical (48h) |
| `{$OZBX_BACKUP_ANY_WARN}` | `1440` | Minutos sem qualquer backup warning |
| `{$OZBX_BACKUP_ANY_CRIT}` | `2880` | Minutos sem qualquer backup critical |

---

## Modo Debug

Para obter JSON completo com metadados adicionais de diagnostico:

```sh
$DLC/bin/mpro /<Banco de dados> -ld <Banco de dados> -b -q -p /openedgezbx/openedgezbx.p -param "debug=true"
```

O modo debug inclui informacoes extras sobre:
- Parametros de conexao brutos (`DBPARAM`)
- Valores intermediarios de calculo
- Timestamps detalhados

---

## Categorias de metricas

### `metrics.io` — I/O e Armazenamento
`buffer_hit_ratio`, `physical_reads_per_sec`, `physical_writes_per_sec`,
`checkpoint_frequency_per_min`, `bi_log_usage_percent`, `ai_log_growth_per_hour`,
`disk_free_percent`, `db_block_size`, `bi_block_size`, `ai_block_size`,
`hi_water_total_blocks`, `free_blocks`, `logical_reads_total`,
`physical_reads_total`, `db_writes_total`, `areas_count`,
`log_file_size_mb`, `log_file_size_bytes`.

### `metrics.memory` — Memoria e Buffers
`buffer_pool_used_percent`, `lru_scans_per_sec`, `lock_table_used_percent`,
`lock_table_current`, `lock_table_hwm`, `buffer_pool_current`, `buffer_pool_hwm`,
`shared_memory_used_percent`, `hash_chain_avg_length`.

### `metrics.transactions` — Transacoes
`tps`, `active_transactions`, `long_transactions_over_60s`,
`longest_transaction_age_sec`, `rollback_rate_percent`, `bi_cluster_avg_size_kb`,
`avg_transaction_duration_sec`, `commits_total`, `undos_total`, `transactions_total`.

### `metrics.locks` — Bloqueios
`lock_waits_per_sec`, `lock_timeouts_per_hour`, `deadlocks_per_hour`,
`active_record_locks`, `avg_lock_wait_ms`, `lock_waits_total`.

### `metrics.connections` — Conectividade
`active_connections`, `max_connections`, `active_vs_max_percent`,
`self_connections`, `remote_connections`, `batch_connections`,
`idle_sessions_over_30min`, `connection_errors_per_hour`,
`appserver_available_agents`, `nameserver_availability`,
`biw_process`, `aiw_process`, `wdog_process`, `apw_process`.

### `metrics.services` — Servicos
`database_online`, `appserver_status`, `nameserver_status`, `listener_status`.

### `metrics.license` — Licenciamento
`lic_valid_users`, `lic_current_connections`, `lic_active_connections`,
`lic_batch_connections`, `lic_usage_percent`, `lic_max_active`,
`lic_max_batch`, `lic_max_current`.

### `metrics.storage` — Estrutura de blocos, capacidade e features
`blocks_in_use`, `total_db_size_gb`, `used_db_size_gb`, `free_reusable_gb`,
`unformatted_gb`, `free_reusable_pct`, `consumed_hwm_pct`,
`buffer_b_alloc_pct`, `buffer_b1_alloc_pct`, `buffer_b_memory_gb`, `buffer_b1_memory_gb`,
`num_areas`, `num_locks`, `most_locks`, `bi_size`,
`feat_large_files`, `feat_64bit_dbkeys`, `feat_large_keys`, `feat_64bit_sequences`,
`feat_encryption`, `feat_auditing`, `feat_replication`, `feat_multitenancy`, `feat_cdc`,
`areas_at_risk_count`, `areas_at_risk_names`,
`areas_with_fixed_last_extent`, `areas_with_variable_last_extent`.

### `metrics.backup` — Monitoramento de backup
`minutes_since_full_backup`, `minutes_since_incr_backup`,
`minutes_since_any_backup`, `last_backup_type`.

### `metrics.servers` — Brokers e servidores
Contagem por tipo (4GL vs SQL), brokers, portas, current/max users, logins, pending,
atividade: bytes/mensagens/records sent/received, queries.

### `metrics.configuration` — Parametros de Startup
`startup_B`, `startup_B1`, `startup_L`, `startup_n`, `startup_spin`, `startup_bi`,
`db_create_date`, `db_last_open_date`.

---

## VSTs utilizadas

| VST / Fonte | Campos utilizados | Metricas alimentadas |
|---|---|---|
| `_DbStatus` | `_DbStatus-StartTime`, `_DbStatus-DbName`, `_DbStatus-fbDate`, `_DbStatus-ibDate`, `_DbStatus-ibSeq`, `DbBlkSize`, `HiWater`, `FreeBlks`, `EmptyBlks`, `TotalBlks`, `RMFreeBlks`, `NumAreas`, `NumLocks`, `MostLocks`, `BiSize` | status, identificacao, storage, backup |
| `_ActSummary` | `_Summary-DbWrites`, `_Summary-Commits`, `_Summary-Undos`, `_Summary-TransComm`, `_Summary-Chkpts`, `_Summary-UpTime` | writes/s, TPS, rollback%, totais, uptime |
| `_ActBuffer` | `_Buffer-LogicRds`, `_Buffer-OSRds`, `_Buffer-Chkpts`, `_Buffer-LRUSkips` | buffer hit ratio, reads/s, ckpt/min, LRU/s |
| `_Connect` | `_Connect-Type`, `_Connect-Name`, `_Connect-Pid` | sessoes ativas, tipo SELF/BATCH/REMOTE, processos BIW/AIW/WDOG/APW |
| `_AreaStatus` | `_AreaStatus-Hiwater`, `_AreaStatus-Freenum` | hi-water blocks, free blocks |
| `_Area` | `_Area-blocksize`, `_Area-name`, `_Area-number` | db_block_size, contagem de areas |
| `_AreaExtent` | tipo (fixo=37, variavel=5/4), area, tamanho, espaco livre | areas at risk, classificacao fixo/variavel |
| `_MstrBlk` | `_MstrBlk-biblksize`, `_MstrBlk-aiblksize`, `_MstrBlk-rlclsize`, `_MstrBlk-crdate`, `_MstrBlk-oprdate`, `_MstrBlk-dbvers` | BI/AI block size, datas |
| `_Database-Feature` | `_DBFeature_Name`, `_DBFeature_Active`, `_DBFeature_Id` | 9 features do banco (Large Files, Encryption, etc.) |
| `_ActBILog` | `_BiLog-BytesWrtn` | BI log bytes escritos |
| `_ActAILog` | `_AiLog-BytesWritn` | AI log growth/hour |
| `_Resrc` | `_Resrc-Id`, `_Resrc-lock`, `_Resrc-Name`, `_Resrc-time`, `_Resrc-wait` | lock table e buffer pool |
| `_ActLock` | `_Lock-ExclWait`, `_Lock-ShrWait`, `_Lock-UpgWait`, `_Lock-RecGetWait` | lock_waits/s |
| `_Trans` | `_Trans-State`, `_Trans-Duration` | transacoes ativas, longas, duracao |
| `_License` | `_Lic-ActiveConns`, `_Lic-BatchConns`, `_Lic-CurrConns`, `_Lic-MaxActive`, `_Lic-MaxBatch`, `_Lic-MaxCurrent`, `_Lic-ValidUsers` etc. | licenciamento, usage % |
| `_Servers` | tipo (4GL vs SQL), PID, porta, current/max users, logins, pending | brokers, servidores |
| `_ActServer` | bytes/mensagens/records sent/received, queries | atividade de servidores |
| `FILE-INFO` | `FILE-SIZE` em `PDBNAME(1) + ".lg"` | log_file_size_mb, log_file_size_bytes |
| `DBPARAM(1)` | (parsing de string) | -B, -B1, -L, -n, -spin, -bibufs |

### Nomes reais de `_Resrc-Name` (validados no OE 12.8)

| Uso no coletor | _Resrc-Name real | Nota |
|---|---|---|
| lock_table_current / active_record_locks | `Record Lock` | Sem 's' — NAO "Record Locks" |
| buffer_pool_current | `DB Buf Avail` | NAO existe "Buffers" generico |

Lista completa dos 27 registros: `Shared Memory`, `Record Lock`, `Schema Lock`, `Trans Commit`, `DB Buf I Lock`, `Record Get`, `DB Buf Read`, `DB Buf Write`, `DB Buf Backup`, `DB Buf S Lock`, `DB Buf X Lock`, `DB Buf Avail`, `DB Buf S Lock LRU2`, `DB Buf X Lock LRU2`, `DB Buf Write LRU2`, `BI Buf Read`, `BI Buf Write`, `AI Buf Read`, `AI Buf Write`, `TXE Share Lock`, `TXE Update Lock`, `TXE Commit Lock`, `TXE Excl Lock`, `Repl TEND Ack`, `DB Svc enqueue`, `Encryption buffer`, `Statement cache`.

---

## Limitacoes conhecidas

1. **Taxas sao medias acumuladas desde o startup** do banco. Para taxa instantanea, usar item Zabbix `Change per second` sobre os campos `*_total`.

2. **Logs `.lg` nao sao parseados** (conteudo). Metricas como `lock_timeouts_per_hour`, `deadlocks_per_hour` e `connection_errors_per_hour` ficam `null`. O **tamanho** do `.lg` e coletado via `FILE-INFO:FILE-SIZE` (v1.2.0).

3. **Espaco em disco (`disk_free_percent`)** nao e exposto pelas VSTs; coletar via shell externo.

4. **`shared_memory_used_percent`** nao e exposto via VST; usar `ipcs` / `/proc/meminfo`.

5. **`appserver_*` e `nameserver_*`** ficam `null`; coletar via OEM ou `asbman` / `nsman`.

6. **PID do processo** fixo em `0` — `_MyConnection` e ambiguo no OE 12.2+. Injetado externamente pelo shell collector.

7. **`DBPARAM(1)`** em conexao remota retorna parametros separados por virgula e nao traz `-B`/`-B1`/`-L`/`-n` (server-side).

8. **`idle_sessions_over_30min`** nao e derivavel do `_Connect` (sem campo last-activity).

9. **`_Resrc` nao possui campo HWM** — metricas de HWM ficam `null`.

10. **Saida JSON** requer fatiamento da `LONGCHAR` em chunks `CHARACTER` de 30K (limitacao do runtime ABL).

11. **`_DbServiceManagerObjects`** — descoberta mas nao implementada. Servicos monitorados futuramente.

---

## Manutencao e extensao

### Adicionar uma nova metrica

1. Localize a procedure `pCollectXxx` correspondente em `openedgezbx.p`.
2. Adicione `DEFINE VARIABLE` no topo.
3. Crie um bloco `DO ON ERROR UNDO, LEAVE:` consultando a VST com `NO-LOCK NO-ERROR`.
4. Concatene um novo `fnMetric(...)` no `gcSecXxx` correspondente.
5. **Calculos com divisao:** sempre proteger divisao por zero retornando 0 (nao null) para evitar erro JSONPath no Zabbix.

### Adicionar uma nova categoria

1. Crie nova procedure `pCollectXxx`.
2. Declare nova variavel global `gcSecXxx AS LONGCHAR`.
3. Faca `RUN pCollectXxx NO-ERROR` no `MAIN-BLOCK`.
4. Adicione a nova secao em `pBuildJson`.

### Convencoes

- Toda VST acessada com `NO-LOCK`.
- Todo `FIND` com `NO-ERROR` + checagem `IF AVAILABLE`.
- Metricas indisponiveis retornam `null` com `observation`.
- Metricas calculadas retornam `0` (nao `null`) quando divisor e zero.
- Aspas via `gcQ = CHR(34)`, chaves via `gcLB = CHR(123)` / `gcRB = CHR(125)`.
- NUNCA usar aspas simples, `~"`, `{` ou `}` literais em strings ABL.
- Numeros decimais < 1 devem ter zero a esquerda (`fnJsonNum` ja trata isso).
- Para database features, usar `_Database-Feature` (NAO `_MstrBlk-integrity`).
- Consultar `CHANGELOG.md` para historico de correcoes de campos VST.

---

## Licenca / Autoria

Coletor `openedgezbx` v1.0.0 — Progress ABL — compativel com OpenEdge 12.2+ (validado em 12.2 e 12.8).
Desenvolvido por Thiago Santana / UAIZABBIX.
