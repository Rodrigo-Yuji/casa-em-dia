# Casa em dia

PWA em português para tarefas domésticas compartilhadas. Interface estática, Supabase Auth, PostgreSQL com RLS e RPCs, Web Push por Edge Function e agendamento por pg_cron.

## Usar

1. Abra o site e escolha **Criar minha casa online**. A demonstração é local e não grava exemplos no banco.
2. Crie uma conta com e-mail e senha, confirme o e-mail e entre.
3. Crie a casa e adicione os moradores. Compartilhe o código de convite apenas com eles.
4. Cada morador entra com sua conta, escolhe o perfil existente e vincula suas tarefas.
5. No celular, adicione à Tela de Início. Em Configurações, ative as notificações e faça o teste.

O GitHub Pages é público. Os dados da casa exigem login no Supabase e pertencimento à casa; o código de convite deve ser compartilhado apenas com os moradores. O endereço de produção é https://Rodrigo-Yuji.github.io/casa-em-dia/.

## Divisão de tarefas

Cada tarefa tem seu próprio rodízio, guiado por quem realmente a fez. Quem ainda não fez tem prioridade; depois, quem fez há mais tempo. Empates são resolvidos pela menor carga estimada do dia, menor número de tarefas, preferência inicial e ID estável. Quem cobre outra pessoa avança para o fim da fila daquela tarefa; o responsável mantém sua vez. A distribuição inicial por minutos é planejada separadamente das conclusões: fazer ou cobrir uma tarefa nunca transfere outras tarefas, nem hoje nem nas previsões futuras. O histórico de cada tarefa só altera o rodízio dela. Ausentes são pulados, mantêm sua prioridade ao retornar e não acumulam tarefas atrasadas. Se todos estiverem ausentes, a tarefa fica sem responsável.

A agenda futura simula conclusões pelos responsáveis previstos, por até 366 dias; coberturas e ausências alteram as previsões. Conclusões anteriores preservam o responsável e quem fez. O cliente envia o responsável exibido ao concluir; o banco rejeita uma conclusão se o rodízio tiver mudado, evitando registrar dívida contra a pessoa errada.

Coberturas são compensadas somente pela fila: quem realmente faz vai para o fim do rodízio; quem foi coberto mantém a próxima vez em que estiver disponível. Não existe dívida nem quitação adicional. O histórico preserva a tarefa, a data, o responsável e quem fez, apenas para reconhecer a participação e apoiar conversas. Registros antigos são preservados; não são convertidos em cobranças. Uma pessoa coberta não recebe duas tarefas no dia seguinte; recebe somente a próxima ocorrência da mesma tarefa.

As tarefas têm uma cor por morador (também identificadas pelo nome, sem depender apenas da cor), marcação de “Minha tarefa” e filtros com o nome de todos os moradores. A paleta é compartilhada e determinada pela ordem dos moradores da casa. “Todas as tarefas” é um catálogo de cadastros, com recorrências e abas separadas para tarefas recorrentes e de único dia; inclui filtro de ativas/arquivadas. O perfil do usuário abre Configurações.

## Cadastro e e-mail

O aplicativo possui cadastro, login, tratamento do retorno de confirmação e solicitação de reenvio. A confirmação depende da configuração do Auth no Supabase e da entrega do provedor de e-mail. O sucesso de uma solicitação não comprova entrega. Configure o Site URL e os Redirect URLs com a origem publicada e use SMTP próprio para os moradores. Não foram desativadas confirmações nem confirmadas contas manualmente.

## Notificações e offline

O servidor verifica tarefas a cada minuto, considerando o fuso da casa (America/Sao_Paulo), a redistribuição por ausência e os horários. Envia uma vez por tarefa/data/dispositivo, com até três tentativas no intervalo de 15 minutos após o horário. Não recupera alertas de mais de 15 minutos atrás. Cada morador deve vincular sua conta e ativar notificações em cada aparelho.

No iPhone, Web Push exige iOS 16.4+ e abertura pelo ícone adicionado à Tela de Início. Foco, permissões, rede e decisões do sistema podem atrasar ou silenciar notificações. Web Push não equivale a um alarme de despertador e não garante som nem horário exato.

O service worker guarda os arquivos do aplicativo. Um cache por usuário permite consultar os últimos dados sincronizados sem conexão. Alterações online só são confirmadas depois da resposta do Supabase; não há fila de gravações offline. A demonstração usa armazenamento local separado. Nunca há fallback silencioso de uma gravação online para uma gravação local.

## Segurança

As tabelas públicas têm RLS e apenas leitura restrita à própria casa. As alterações passam por RPCs com escopo de casa e identidade autenticada. As chaves privadas VAPID e o segredo do agendador estão exclusivamente no schema privado do banco. A Edge Function autentica o agendador por segredo e os testes por Supabase Auth; seu verificador de JWT de gateway está desligado para permitir o agendador, com autenticação dentro da função. Nenhuma chave service_role está no cliente ou no repositório.

## Verificação

- `node --check app.js`
- `node --check sw.js`
- `node tests/client.cjs`
- `tests/database.sql` e `tests/task-isolation.sql`: cenários transacionais com rollback, sem dados de teste persistidos.

Os arquivos SQL em database/ são o histórico aplicado, em ordem: schema.sql, redistribution.sql, push.sql, reminder-schedule.sql, assignment-fix.sql, rotation-and-specific-favors.sql, validate-current-responsibility.sql, rotation-indexes.sql, rotation-without-extra-debt.sql, isolate-task-rotation.sql. Não reaplicar em banco já migrado. As chaves de push foram provisionadas separadamente, sem incluir valores secretos no código.

## Recorrência a cada X dias e controles privados

Em Nova tarefa ou Editar tarefa, escolha **A cada X dias**, informe o intervalo de 1 a 365 e a data **Começando a partir de**. As datas seguem essa referência, inclusive ao mudar de mês. Concluir uma tarefa atrasada não desloca o calendário.

Use **＋ Controle privado** no seletor Controle para criar um espaço entre você e outro morador já cadastrado. Só esses dois participantes veem as tarefas, ausências e histórico desse espaço. A pessoa selecionada acessa o controle pela própria conta vinculada à casa; não é enviado convite por e-mail. O rodízio desse controle não altera a carga ou a sequência da casa inteira. Ausências registradas no controle privado valem somente nele. As tarefas da casa e dos controles privados aparecem juntas em Meu dia, no catálogo e no histórico, com etiquetas que identificam sua visibilidade e os participantes. Não é preciso alternar de controle. Ao criar uma tarefa, escolha explicitamente quem pode vê-la; a visibilidade de uma tarefa existente é preservada ao editar.

Os testes SQL de autorização incluem tentativas de leitura e alteração por um terceiro usuário, inclusive acesso direto às tabelas com RLS. As tabelas dos controles privados são separadas das tabelas da casa.

## Gestão de controles e tarefas

Em Pessoas e ausências, a seção Controles privados fica antes de Convide quem mora com você. Crie um controle para Só eu ou para você e outro morador. O criador pode renomear ou excluir o controle. Os participantes ficam fixos para não expor um histórico existente a uma pessoa nova. Excluir um controle exige confirmação e apaga suas tarefas, ausências e histórico; a casa e os outros controles permanecem intactos.

No catálogo Todas as tarefas, Arquivadas é uma seção recolhida por padrão dentro de cada categoria. É possível reativar, editar e excluir uma tarefa arquivada. Excluir uma tarefa exige confirmação, remove-a da rotina e das listas e preserva as realizações anteriores no histórico. O banco guarda uma marca de exclusão para impedir reativação acidental pelo aplicativo.

## Gerenciar várias casas

Configurações → Gerenciar casas permite criar outra casa, entrar por convite, trocar a casa em uso e definir a casa padrão. A casa padrão é aberta ao iniciar o aplicativo. Cada casa conserva seus próprios moradores, tarefas e controles privados. Uma conta pode pertencer a várias casas, com um perfil por casa.

Para entrar na casa de outra pessoa após criar uma casa por engano: use Entrar por convite, cole o código recebido e, se seu nome já existir, vincule esse perfil. A opção Tornar esta casa a minha padrão vem marcada. Depois você pode excluir a casa criada por engano, sem precisar apagar sua conta.

Só o responsável pode renomear ou excluir uma casa. Excluir pede que ele digite o nome exato e apaga todos os dados dessa casa, inclusive controles privados, para todos os moradores. Outros moradores podem sair da casa; seus perfis e históricos são preservados, mas eles perdem o acesso e deixam de participar do rodízio. Ao entrar novamente, o perfil anterior é reativado. As notificações identificam a casa para abrir o contexto correto.

## Logout e remoção de moradores

O botão Sair da conta está disponível mesmo sem casa, na tela vazia e no formulário de criação/entrada. O logout local não depende da resposta da rede nem da inicialização das notificações. Respostas vazias bem-sucedidas de RPCs (como exclusões e ações sem retorno) são aceitas, evitando erro de JSON após uma operação já concluída.

Em Pessoas e ausências, o responsável da casa pode remover outro morador ou um perfil ainda sem conta vinculada. O perfil e o histórico são preservados, mas ele deixa de participar do rodízio e perde o acesso aos dados e controles privados daquela casa. A remoção renova o convite para impedir reentrada com o código antigo. Outras casas da pessoa permanecem intactas. Quando o criador de um controle privado é removido, o outro participante ativo com conta vinculada passa a gerenciá-lo. O responsável não pode remover a si próprio.
