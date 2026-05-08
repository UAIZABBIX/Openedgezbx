# Configuracao do Zabbix Agent2 para openedgezbx

Guia completo para configurar o Zabbix Agent2 (versao 7.0+) para coletar metricas do OpenEdge via templates openedgezbx.

## Pre-requisitos

- Zabbix Agent2 instalado no servidor do banco OpenEdge
- Zabbix Server/Proxy versao **7.0+** (templates usam formato YAML 7.0)
- Coletor `openedgezbx_collector.sh` configurado e agendado no cron
- Arquivos JSON sendo gerados em `/openedgezbx/json_zbx/`

---

## 1. Configuracao do Agent2

Edite o arquivo de configuracao do Zabbix Agent2:

```sh
vi /etc/zabbix/zabbix_agent2.conf
```

### Parametros obrigatorios

```ini
# Servidor Zabbix (para modo passivo)
Server=<IP_DO_ZABBIX_SERVER>

# Servidor Zabbix (para modo ativo)
ServerActive=<IP_DO_ZABBIX_SERVER>

# Hostname — deve coincidir com o cadastro no Zabbix frontend
Hostname=openedgerdbms001
```

### Parametro critico: DenyKey + AllowKey

O Agent2 precisa de permissao para executar `vfs.file.contents` e `vfs.dir.get`.
**IMPORTANTE:** Ao usar `AllowKey`, e **obrigatorio** incluir tambem `DenyKey=system.run[*]`.

```ini
# OBRIGATORIO — DenyKey deve vir ANTES dos AllowKey
DenyKey=system.run[*]

# Permite leitura de arquivos no diretorio do coletor
AllowKey=vfs.file.contents[/openedgezbx/json_zbx/*]
AllowKey=vfs.dir.get[/openedgezbx/json_zbx,*]
```

Alternativamente, copie o arquivo de configuracao incluso no projeto:

```sh
cp /openedgezbx/zabbix_templates/openedgezbx.conf /etc/zabbix/zabbix_agent2.d/
```

### Timeout

Os arquivos JSON podem ter alguns KB. Aumente o timeout se necessario:

```ini
Timeout=10
```

### Permissoes de arquivo

O usuario do agent2 (geralmente `zabbix`) precisa ler os JSONs:

```sh
# Verifica qual usuario roda o agent2
grep "^User=" /etc/zabbix/zabbix_agent2.conf

# Garante permissao de leitura
chmod 644 /openedgezbx/json_zbx/*.json
# Ou adiciona o usuario zabbix ao grupo do owner
usermod -aG <grupo_progress> zabbix
```

---

## 2. Reinicie o Agent2

```sh
systemctl restart zabbix-agent2
systemctl status zabbix-agent2
```

---

## 3. Teste de conectividade

### No servidor do banco (teste local)

```sh
# Testa se o agent2 consegue listar os JSONs
zabbix_agent2 -t 'vfs.dir.get[/openedgezbx/json_zbx]'

# Testa se consegue ler um JSON especifico
zabbix_agent2 -t 'vfs.file.contents[/openedgezbx/json_zbx/producao_bancos_emsfnd.json]'
```

### No Zabbix Server (teste remoto)

```sh
# Modo passivo — o server consulta o agent
zabbix_get -s <IP_DO_AGENT> -k 'vfs.dir.get[/openedgezbx/json_zbx]'
zabbix_get -s <IP_DO_AGENT> -k 'vfs.file.contents[/openedgezbx/json_zbx/producao_bancos_emsfnd.json]'
```

---

## 4. Importar os templates no Zabbix

### Requisitos do template

Os templates sao formato **YAML Zabbix 7.0** (`version: '7.0'`). Particularidades:
- Usam `template_groups` (nao `groups` — mudou na 7.0)
- UUIDs sao UUIDv4 validos (32 caracteres hexadecimais)
- `sortorder` nos graph_items e string (`'1'`), nao inteiro
- Discovery usa regex (`\.json$`), nao glob

### Via Frontend

1. Acesse **Configuration > Templates > Import**
2. Importe o arquivo:
   - `zabbix_templates/openedgezbx_passive.yaml` — para coleta **passiva** (server consulta o agent)
   - `zabbix_templates/openedgezbx_active.yaml` — para coleta **ativa** (agent envia ao server)
3. Marque **Create new** e **Update existing**
4. Clique em **Import**

### Escolha passivo vs ativo

| Modo | Quando usar |
|---|---|
| **Passivo** (`openedgezbx_passive`) | Agent acessivel pelo Zabbix Server via rede (porta 10050) |
| **Ativo** (`openedgezbx_active`) | Agent atras de firewall/NAT, ou muitos hosts (mais escalavel) |

---

## 5. Vincular template ao host

1. Acesse **Configuration > Hosts**
2. Selecione o host do servidor OpenEdge (ou crie um novo)
3. Em **Templates**, adicione:
   - `OpenEdge RDBMS - Passive` **ou** `OpenEdge RDBMS - Active`
4. Verifique/ajuste a macro `{$OZBX_JSON_DIR}`:
   - Padrao: `/openedgezbx/json_zbx`
   - Altere se o diretorio for diferente

---

## 6. Verificar autodiscovery

Apos vincular o template, aguarde o intervalo de discovery (padrao: 5 minutos).

1. Acesse **Configuration > Hosts > [seu host] > Discovery rules**
2. Verifique se "OpenEdge: Database Discovery" esta ativo
3. O discovery usa `vfs.dir.get[{$OZBX_JSON_DIR}]` com filtro regex `\.json$`
4. A macro LLD e `{#PATHNAME}` (caminho absoluto do JSON — campo real do `vfs.dir.get`)
5. Em **Monitoring > Latest data**, filtre pelo host
6. Os itens devem aparecer como `OpenEdge [producao_bancos_emsfnd.json]: ...`

### Recursos autodescobertos por banco

| Recurso | Quantidade |
|---|---|
| Item prototypes (dependent items com JSONPath) | 104 |
| Graph prototypes | 34 |
| Trigger prototypes | 19 |

---

## 7. Macros ajustaveis (thresholds)

Ajuste no host ou template conforme seu ambiente:

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

## 8. Triggers incluidos

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

---

## 9. Graph prototypes (34 por banco)

Os templates incluem 34 graph prototypes autodescobertos para cada banco, cobrindo:
- Buffer hit ratio ao longo do tempo
- Physical reads e writes por segundo
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

---

## 10. Arquitetura do fluxo

```
[Cron 1min]
    |
    v
openedgezbx_collector.sh
    |
    +-- proutil -C dbipcs --> lista bancos carregados
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

## Deteccao automatica de bancos offline (inventario)

A partir da v1.3.1, o `openedgezbx_collector.sh` mantem um arquivo `.openedgezbx_inventory` no diretorio do script que rastreia todos os bancos ja vistos. Esse mecanismo permite detectar automaticamente quando um banco sai do ar.

### Como funciona

Quando um banco que ja foi visto anteriormente desaparece da saida do `proutil -C dbipcs`, o collector:
1. Detecta a ausencia comparando o inventario com a lista atual de bancos
2. Gera um JSON minimo com `database_online: false` e `db_status: "offline"`
3. O JSON offline mantem todas as secoes de metricas com valores 0/false para evitar erros de JSONPath

### Trigger "Database OFFLINE"

- **Severidade: Disaster** (nivel maximo no Zabbix)
- Dispara imediatamente quando `database_online` muda para `false`
- Resolve automaticamente quando o banco volta ao ar e a coleta normal gera `database_online: true`

### Comportamento esperado no Zabbix

| Situacao | JSON gerado | Trigger |
|---|---|---|
| Banco online, coleta OK | JSON completo com metricas reais | Nenhum (resolved) |
| Banco online, mpro falha | JSON minimo `database_online=false` | Database OFFLINE (Disaster) |
| Banco offline (sumiu do dbipcs) | JSON minimo `database_online=false` via inventario | Database OFFLINE (Disaster) |
| Banco volta ao ar | JSON completo com metricas reais (sobrescreve) | Trigger resolve automaticamente |

**Nota:** O arquivo `.openedgezbx_inventory` e criado automaticamente e nao deve ser editado manualmente em operacao normal. Se necessario remover um banco do monitoramento (por exemplo, banco descomissionado), remova a linha correspondente do inventario.

---

## Troubleshooting

| Problema | Solucao |
|---|---|
| Discovery nao encontra bancos | Verifique se existem .json em `{$OZBX_JSON_DIR}` e se o agent2 tem permissao de leitura |
| Itens "Not supported" | Rode `zabbix_agent2 -t 'vfs.file.contents[<caminho>]'` para ver o erro. Para metricas calculadas, verifique se o valor e 0 (nao null) |
| Erro na importacao do template | Verifique se o Zabbix e 7.0+; templates usam `template_groups` e UUIDv4 |
| JSON invalido | Rode `python -m json.tool < arquivo.json` para validar |
| Valores null no Zabbix | Normal para metricas que dependem de execucao local ou dados externos. Metricas calculadas (storage, backup) retornam 0, nao null |
| Metricas desatualizadas | Verifique se o cron esta rodando: `crontab -l` |
| AllowKey nao funciona | Verifique se `DenyKey=system.run[*]` esta presente ANTES dos AllowKey |
| Graph prototypes nao aparecem | Aguarde o intervalo de discovery (5 min) e verifique se ha dados nos items |
| Banco aparece offline | Verifique se mpro consegue conectar; collector gera JSON minimo com database_online=false. Se o banco foi descomissionado, remova-o do `.openedgezbx_inventory` |
| Trigger OFFLINE nao dispara | Verifique se `.openedgezbx_inventory` existe e contem o banco. O inventario e criado na 1a execucao do collector |
| Trigger OFFLINE nao resolve | Verifique se o banco voltou ao `proutil -C dbipcs` e se o cron esta rodando |
