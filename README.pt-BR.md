# Agents Team

> Um chat em grupo no terminal entre **você**, o **Claude Code** e o **Codex** — como um grupo de WhatsApp com três participantes.

[English](README.md) · **Português**

Você digita e os agentes de IA respondem na mesma conversa: eles veem as mensagens um do outro e as suas, e reagem entre si. Por baixo dos panos, o script mantém um único histórico compartilhado e, a cada mensagem, envia o fio inteiro para cada agente (via o CLI dele) e cola a resposta de volta — então todos sempre enxergam a mesma conversa.

---

## Pré-requisitos

1. **Python 3** — confira com `python3 --version`.
2. **Claude Code** instalado e autenticado — confira com `claude --version`.
3. **Codex CLI** instalado e autenticado — confira com `codex --version`.

**Plataformas:** funciona direto no Linux, macOS e no **WSL** (Windows Subsystem for Linux). No Windows nativo (PowerShell) o script Python roda igual, mas a etapa do atalho é diferente e o `claude`/`codex` precisam estar instalados como comandos do próprio Windows — veja [Windows nativo](#windows-nativo).

---

## Instalação

```bash
bash install.sh
```

O instalador:

- cria o script em `~/scripts/agents_team.py`;
- registra os comandos `agents-team` e `agents-team-personal` no arquivo de inicialização certo do seu shell (ele detecta sozinho **zsh** → `~/.zshrc` ou **bash** → `~/.bashrc`).

Depois de instalar, **abra um terminal novo** (ou rode `source ~/.zshrc` / `source ~/.bashrc`) para os comandos passarem a valer.

> Prefere não rodar um script? Salve o `agents_team.py` em qualquer pasta e adicione o atalho você mesmo:
> ```bash
> echo "alias agents-team='python3 /caminho/para/agents_team.py'" >> ~/.zshrc   # ou ~/.bashrc
> source ~/.zshrc
> ```

---

## Como usar

Entre na pasta do projeto sobre o qual quer conversar e rode o comando:

```bash
cd ~/caminho/do/seu/projeto
agents-team
```

> O contexto vem da pasta em que você está: rodando dentro de um projeto, os agentes enxergam o conteúdo dele (`CLAUDE.md`, código). Para um papo neutro, rode de uma pasta vazia.

Vai aparecer um prompt `You:`. A partir daí:

| O que você digita | O que acontece |
|---|---|
| uma mensagem + Enter | **todos** os agentes respondem (a ordem reveza a cada rodada) |
| `@nome mensagem` | só aquele agente responde (ex.: `@codex o que você acha?`) |
| Enter vazio | os agentes continuam a conversa **entre si** por uma rodada |
| `/clear` | começa a conversa do zero (sem reiniciar o programa) |
| `/save` | salva o histórico atual em um arquivo `.md` |
| `/help` | mostra os comandos |
| `/exit` | encerra |

As respostas chamam os CLIs de verdade, então levam alguns segundos por agente (aparece "is typing…" enquanto isso).

---

## Perfis e criação de agentes

Um **perfil** define quais agentes participam do time e qual comando inicia cada um. Dois comandos já vêm configurados:

| Comando | Inicia |
|---|---|
| `agents-team` | o perfil `work` (padrão) |
| `agents-team-personal` | o perfil `personal` |
| `python3 ~/scripts/agents_team.py --profiles` | lista os perfis configurados |
| `python3 ~/scripts/agents_team.py --profile NOME` | inicia um perfil específico |

Os perfis são independentes, então dá para rodar o `work` em um terminal e o `personal` em outro, ao mesmo tempo.

### Onde se configura

No topo do `agents_team.py` existe um bloco `PROFILES`. Cada perfil é uma **lista de agentes**; cada agente tem um `name`, um `cmd` (como iniciar o CLI) e, opcionalmente, uma `instruction` (o papel dele):

```python
PROFILES = {
    "work": [
        {"name": "Claude", "cmd": ["claude", "-p"]},
        {"name": "Codex",  "cmd": ["codex", "exec"]},
    ],
    "personal": [
        # Exemplo com nomes de comando alternativos — ajuste ao seu setup.
        {"name": "Claude", "cmd": ["claude-pessoal", "-p"]},
        {"name": "Codex",  "cmd": ["codex-pessoal", "exec"]},
    ],
}
DEFAULT_PROFILE = "work"
```

> O perfil `personal` é um **exemplo** que usa nomes de comando alternativos. Edite os valores de `cmd` para comandos que existem na sua máquina.

### Criar um agente (e dar um papel a ele)

Para adicionar um terceiro participante, basta incluir um item na lista. Preenchendo `instruction`, você dá um papel a ele — ótimo para um "advogado do diabo" embutido:

```python
    "review": [
        {"name": "Claude",  "cmd": ["claude", "-p"]},
        {"name": "Codex",   "cmd": ["codex", "exec"]},
        {"name": "Skeptic", "cmd": ["claude", "-p"],
         "instruction": "Your role is devil's advocate: question assumptions and flag risks and costs."},
    ],
```

Depois rode `python3 ~/scripts/agents_team.py --profile review`. Você pode ter 2, 3 ou mais vozes, misturar comandos de trabalho e pessoais, etc. Use **nomes únicos** dentro de cada time (o `@nome` usa o nome).

---

## Onde ficam os arquivos salvos

O `/save` gera um arquivo `team_<perfil>_<data-hora>.md` **na pasta em que você roda o comando**. Se você roda de dentro do projeto, ele fica junto do projeto.

---

## Solução de problemas

**`command not found: agents-team`**
Abra um terminal novo — o atalho só vale em shells iniciados depois da instalação. Se ainda falhar, confirme que o atalho está no arquivo de inicialização do seu shell (`~/.zshrc` para zsh, `~/.bashrc` para bash) e rode `source` nele.

**`[error] 'claude' (profile 'work') is not on your PATH`**
O CLI daquele perfil não foi encontrado. Confira se ele está instalado e logado (`claude --version`, `codex --version`) e se o nome em `cmd`, dentro do bloco `PROFILES`, está correto.

**As respostas demoram / a conversa ficou enorme.** Cada turno chama os CLIs de verdade, então alguns segundos por agente é o esperado. O histórico inteiro é reenviado a cada turno, então conversas muito longas ficam mais lentas e caras — use `/clear` para começar do zero.

---

## Windows nativo

No Windows nativo (sem WSL), o `agents_team.py` roda normalmente com Python, mas:

- não há `bash`/`alias` — inicie direto com `python agents_team.py` (ou crie uma função no perfil do PowerShell);
- o `claude` e o `codex` precisam estar instalados como comandos **do Windows** e no PATH (uma instalação feita dentro do WSL não é visível no Windows nativo).

Se você já usa o WSL, continuar nele é o caminho mais simples.

---

## Privacidade

Os históricos salvos (e qualquer conversa) ficam em texto puro no disco. Se a conversa incluir dados pessoais, guarde os arquivos em um local controlado. O `.gitignore` incluído já exclui `team_*.md` para você não commitar conversas no repositório sem querer.

Os agentes não têm memória entre execuções — cada turno é reenviado com o histórico da sessão atual. Ao fechar o programa, a conversa só permanece se você tiver usado `/save`.

---

## Licença

MIT — veja [LICENSE](LICENSE).
