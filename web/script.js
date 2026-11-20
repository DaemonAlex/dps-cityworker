// DPS City Worker - Control Room. Everything shown here comes from the server.

const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'dps-cityworker';
let state = { sectors: [], workers: [], reports: [] };
let timer = null;

function post(name, body) {
    return fetch(`https://${RES}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body || {}),
    }).then(r => r.json()).catch(() => null);
}

function el(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
}

function showMessage(text, good) {
    const box = document.getElementById('message');
    box.textContent = text;
    box.className = 'message ' + (good ? 'good' : 'bad');
    box.hidden = false;
    clearTimeout(showMessage.t);
    showMessage.t = setTimeout(() => { box.hidden = true; }, 5000);
}

function sectorCard(s) {
    const health = Math.max(0, Math.min(100, Number(s.health) || 0));
    const card = el('div', 'sector-card');
    let status = 'ONLINE';
    if (s.dark) status = 'NO POWER';
    else if (health <= 20) status = 'CRITICAL';
    else if (health <= 50) status = 'WARNING';
    if (s.dark || health <= 20) card.classList.add('critical');
    else if (health <= 50) card.classList.add('warning');

    const head = el('div', 'card-header');
    head.appendChild(el('h3', null, s.label));
    head.appendChild(el('span', 'status-indicator', status));
    card.appendChild(head);

    const wrap = el('div', 'health-bar-container');
    const bar = el('div', 'health-bar');
    bar.style.width = health + '%';
    wrap.appendChild(bar);
    card.appendChild(wrap);

    const details = el('div', 'details');
    details.appendChild(el('p', null, `Health: ${Math.floor(health)}%`));
    details.appendChild(el('p', null, `Work sites: ${s.sites || 0}`));
    details.appendChild(el('p', s.emergency ? 'alert' : null,
        s.emergency ? `Emergency: ${s.emergency} (${s.emergencyMinutes || 0} min)` : 'No emergency'));
    card.appendChild(details);
    return card;
}

function workerRow(w) {
    const row = el('div', 'row');
    const info = el('div', 'row-info');
    info.appendChild(el('strong', null, w.name));
    info.appendChild(el('span', 'dim', w.rank));
    info.appendChild(el('span', 'dim',
        w.job ? `${w.working ? 'Working' : 'Driving to'}: ${w.job}${w.sector ? ' (' + w.sector + ')' : ''}` : 'No job'));
    row.appendChild(info);

    const act = el('div', 'row-act');
    const pick = el('select');
    state.sectors.forEach(s => {
        const o = el('option', null, s.label);
        o.value = s.id;
        pick.appendChild(o);
    });
    const btn = el('button', 'dispatch-btn', 'Send');
    btn.disabled = !!w.working;
    btn.addEventListener('click', async () => {
        btn.disabled = true;
        const res = await post('dispatchWorker', { worker: w.id, sector: pick.value });
        showMessage(res && res.msg ? res.msg : 'No answer from the server', !!(res && res.ok));
        refresh();
    });
    act.appendChild(pick);
    act.appendChild(btn);
    row.appendChild(act);
    return row;
}

function reportRow(r) {
    const row = el('div', 'row');
    const info = el('div', 'row-info');
    info.appendChild(el('strong', null, r.type));
    info.appendChild(el('span', 'dim', r.sector));
    info.appendChild(el('span', 'dim', r.age < 60 ? `${r.age} min ago` : `${Math.floor(r.age / 60)} h ago`));
    row.appendChild(info);

    const act = el('div', 'row-act');
    const btn = el('button', 'dispatch-btn', 'Done');
    btn.addEventListener('click', async () => {
        btn.disabled = true;
        const res = await post('closeReport', { id: r.id });
        if (!res || !res.ok) showMessage('That report could not be closed', false);
        refresh();
    });
    act.appendChild(btn);
    row.appendChild(act);
    return row;
}

function fill(id, items, make, emptyText) {
    const box = document.getElementById(id);
    box.replaceChildren();
    if (!items.length) {
        box.appendChild(el('p', 'dim empty', emptyText));
        return;
    }
    items.forEach(item => box.appendChild(make(item)));
}

function render(data) {
    if (!data || !Array.isArray(data.sectors)) return;
    // A select that is open would be reset by a redraw: leave the screen alone then
    if (document.activeElement && document.activeElement.tagName === 'SELECT') return;
    state = {
        sectors: data.sectors,
        workers: Array.isArray(data.workers) ? data.workers : [],
        reports: Array.isArray(data.reports) ? data.reports : [],
    };
    fill('sectors', state.sectors, sectorCard, 'No sectors');
    fill('workers', state.workers, workerRow, 'Nobody is on shift');
    fill('reports', state.reports, reportRow, 'No open reports');
    document.getElementById('worker-count').textContent = state.workers.length;
    document.getElementById('report-count').textContent = state.reports.length;
    document.getElementById('updated').textContent = 'Updated ' + new Date().toLocaleTimeString();
}

async function refresh() {
    render(await post('refresh'));
}

function open(data) {
    document.getElementById('app').style.display = 'flex';
    render(data);
    clearInterval(timer);
    timer = setInterval(refresh, 10000);
}

function close() {
    document.getElementById('app').style.display = 'none';
    clearInterval(timer);
    timer = null;
}

window.addEventListener('message', event => {
    const msg = event.data || {};
    if (msg.action === 'open') open(msg.data);
    else if (msg.action === 'close') close();
});

document.getElementById('close-btn').addEventListener('click', () => post('closeUI'));
document.addEventListener('keyup', e => { if (e.key === 'Escape') post('closeUI'); });
