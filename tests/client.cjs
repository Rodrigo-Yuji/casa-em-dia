const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const code=fs.readFileSync(__dirname+'/../app.js','utf8').split("document.addEventListener('click',async")[0];
const ctx={console,Intl,Date,URL,crypto:require('crypto').webcrypto,localStorage:{getItem:()=>null},document:{querySelector:()=>({})}};
vm.createContext(ctx);vm.runInContext(code+`\nglobalThis.test={seed,assignments,taskCard,today,plusDate,setState:s=>{state=s;day=today()},setDemo:b=>{demo=b},personColors,personFilters,favors,home,agenda,recurrenceText,setCatalog:(kind,status='all')=>{catalogTab=kind;catalogStatus=status}}`,ctx);
const t=ctx.test,s=t.seed(),d=t.today();t.setState(s);const [a,b,c]=s.members.map(x=>x.id);
const task=s.tasks[0];s.tasks=[task];task.starts_on=t.plusDate(d,-6);
function add(date,actual,expected){const assignment=t.assignments(date)[0];assert.equal(assignment.effective,expected);s.completions.push({id:require('crypto').randomUUID(),task_id:task.id,task_title:task.title,occurrence_date:date,original_member_id:assignment.effective,completed_by:actual,exempt:false,completed_at:date+'T12:00:00Z'})}
add(t.plusDate(d,-6),a,a);add(t.plusDate(d,-5),b,b);add(t.plusDate(d,-4),c,c);
assert.equal(t.assignments(t.plusDate(d,-3))[0].effective,a,'All three rotate before repeat');
s.absences.push({id:'absence',member_id:b,starts_on:t.plusDate(d,-3),ends_on:t.plusDate(d,-1)});
add(t.plusDate(d,-3),a,a);add(t.plusDate(d,-2),c,c);add(t.plusDate(d,-1),a,a);
assert.equal(t.assignments(d)[0].effective,b,'Returning resident keeps place without accumulating extra turns');
add(d,a,b);assert.ok(!t.favors().includes('Favores a retribuir'),'Coverage is displayed as history rather than a debt ledger');
assert.equal(t.assignments(t.plusDate(d,1))[0].effective,b,'Actual helper moves to back, responsible still takes own turn');
assert.ok(t.favors().includes('sem dívida extra'),'History explains single compensation');
s.absences.push({member_id:a,starts_on:d,ends_on:null},{member_id:b,starts_on:d,ends_on:null},{member_id:c,starts_on:d,ends_on:null});
assert.equal(t.assignments(t.plusDate(d,1))[0].effective,null,'All absent leaves task unassigned');
const balanced=t.seed();t.setState(balanced);const assignments=t.assignments(d),mins=balanced.members.map(m=>assignments.filter(x=>x.effective===m.id).reduce((s,x)=>s+x.duration_minutes,0));assert.ok(Math.max(...mins)-Math.min(...mins)<=30,'Initial ties spread workload');
const colors=balanced.members.map(m=>t.personColors(m.id).ink);assert.equal(new Set(colors).size,balanced.members.length,'Each household member has a distinct color');
assert.ok(t.home().includes('person-filters'),'Resident filters appear in the day view');
const filters=t.personFilters(assignments);for(const m of balanced.members)assert.ok(filters.includes(m.name),'Every resident has a filter');
const card=t.taskCard(assignments[0],d);assert.ok(card.includes('assignee-badge')&&card.includes('--person-ink'),'Cards use names and color together');
const held=t.seed();held.tasks=[held.tasks[0]];held.tasks[0].starts_on=t.plusDate(d,-1);held.completions=[{id:'held',task_id:held.tasks[0].id,task_title:held.tasks[0].title,occurrence_date:t.plusDate(d,-1),original_member_id:a,completed_by:b,completed_at:t.plusDate(d,-1)+'T12:00:00Z'}];t.setState(held);assert.equal(t.assignments(d)[0].effective,a,'Covered person keeps next turn even if another resident never did the task');
console.log('PASS: full rotation, coverage keeps the next turn, no extra debt, absences, actual helper queue, per-person colors, resident filters and accessible task labels');
// Regression: doing someone else's easy task must not move your own obligations.
const isolated=t.seed();isolated.members=isolated.members.slice(0,2);isolated.tasks=isolated.tasks.slice(0,3).map((task,i)=>({...task,title:['Limpar areia dos gatos','Regar plantas','Limpar banheiro'][i],duration_minutes:10,assignee_id:a}));t.setState(isolated);
const before=t.assignments(d),helper=a,covered=before.find(x=>x.effective===b);assert.equal(before.filter(x=>x.effective===helper).length,2,'Fixture: helper has two tasks');assert.ok(covered,'Fixture: other person has one task');
const nextBefore=t.assignments(t.plusDate(d,1));
isolated.completions.push({id:'isolation-cover',task_id:covered.id,task_title:covered.title,occurrence_date:d,original_member_id:b,completed_by:helper,completed_at:d+'T12:00:00Z'});
for(const date of [d,t.plusDate(d,1)]){const initial=date===d?before:nextBefore,after=t.assignments(date);for(const task of initial.filter(x=>x.id!==covered.id))assert.equal(after.find(x=>x.id===task.id).effective,task.effective,'Covering one task cannot reassign another task, today or tomorrow')}
console.log('PASS: coverage cannot transfer unrelated duties');

const catalog=t.seed();catalog.tasks[0].recurrence='weekly';catalog.tasks[0].starts_on=t.plusDate(d,30);catalog.tasks[1].recurrence='once';catalog.tasks[1].starts_on=t.plusDate(d,60);catalog.tasks[2].active=false;t.setState(catalog);t.setCatalog('recurring');
let html=t.agenda();assert.ok(html.includes(catalog.tasks[0].title)&&html.includes('Semanal'),'Catalog includes recurring tasks even when not scheduled today');assert.ok(html.includes(catalog.tasks[2].title)&&html.includes('Arquivada'),'Catalog includes archived registrations');assert.ok(!html.includes(catalog.tasks[1].title),'One-off task is separate');t.setCatalog('once');html=t.agenda();assert.ok(html.includes(catalog.tasks[1].title)&&!html.includes(catalog.tasks[0].title),'One-off tab shows its own registered tasks');
console.log('PASS: catalog lists registered recurrences independent of date and separates one-off tasks');
