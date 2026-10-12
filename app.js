/* ============================================
   RECORDA — shared interactions
   ============================================ */

// ---------- Toast ----------
function showToast(msg){
  let t = document.getElementById('toast');
  if(!t){
    t = document.createElement('div');
    t.id = 'toast';
    t.className = 'toast';
    document.body.appendChild(t);
  }
  t.innerHTML = `<svg class="tick" viewBox="0 0 24 24" fill="none"><path d="M20 6L9 17l-5-5" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg><span>${msg}</span>`;
  t.classList.add('show');
  clearTimeout(t._timer);
  t._timer = setTimeout(()=> t.classList.remove('show'), 2600);
}

// ---------- Overlay open/close ----------
function openOverlay(id){
  const el = document.getElementById(id);
  if(!el) return;
  el.classList.add('open');
  document.body.style.overflow = 'hidden';
}
function closeOverlay(id){
  const el = document.getElementById(id);
  if(!el) return;
  el.classList.remove('open');
  document.body.style.overflow = '';
}
document.addEventListener('click', (e)=>{
  if(e.target.classList && e.target.classList.contains('overlay')){
    e.target.classList.remove('open');
    document.body.style.overflow = '';
  }
});
document.addEventListener('keydown', (e)=>{
  if(e.key === 'Escape'){
    document.querySelectorAll('.overlay.open').forEach(o=> o.classList.remove('open'));
    document.body.style.overflow = '';
  }
});

// ---------- Add-transaction sheet swap ----------
function showAddOptions(){
  document.getElementById('sheet-picker')?.classList.remove('hidden');
  document.getElementById('sheet-form-sale')?.classList.add('hidden');
  document.getElementById('sheet-form-expense')?.classList.add('hidden');
}
function showForm(name){
  document.getElementById('sheet-picker')?.classList.add('hidden');
  document.querySelectorAll('.sheet-form').forEach(f=>f.classList.add('hidden'));
  document.getElementById('sheet-form-'+name)?.classList.remove('hidden');
}

// ---------- Simple form -> success panel ----------
function submitToSuccess(formId, successId, message){
  document.getElementById(formId)?.classList.add('hidden');
  const s = document.getElementById(successId);
  if(s){
    s.classList.remove('hidden');
  }
}

// ---------- Filter chip toggling ----------
function initFilterChips(container){
  const el = document.querySelector(container);
  if(!el) return;
  el.querySelectorAll('.filter-chip').forEach(chip=>{
    chip.addEventListener('click', ()=>{
      el.querySelectorAll('.filter-chip').forEach(c=>c.classList.remove('active'));
      chip.classList.add('active');
    });
  });
}
