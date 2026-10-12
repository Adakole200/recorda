/* ============================================
   RECORDA — Supabase helper
   Load order on every page:
     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
     <script src="supabase.js"></script>
     <script src="app.js"></script>
   Then use the global `Recorda` object.
   ============================================ */

// 1. Paste your values from Supabase → Settings → API
const SUPABASE_URL = 'https://cfptoiusftfvebmuxsva.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_VzAKk-XteHKkvYAwuCqK_w_4mMPbOOz'; // anon key only. NEVER the service_role key.

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Throw on Supabase errors so pages can use try/catch + showToast
function unwrap({ data, error }) {
  if (error) throw new Error(error.message);
  return data;
}

const BIZ_KEY = 'recorda.business_id';

const Recorda = {
  sb,

  // ---------- Auth ----------
  auth: {
    // register.html: signUp({ name, email, phone, password })
    async signUp({ name, email, phone, password }) {
      const { data, error } = await sb.auth.signUp({
        email,
        password,
        options: { data: { full_name: name, phone } },
      });
      if (error) throw new Error(error.message);
      return data; // if email confirmation is ON, data.session is null until they confirm
    },

    // login.html. Email only (phone login needs a paid SMS provider)
    async signIn(email, password) {
      return unwrap(await sb.auth.signInWithPassword({ email, password }));
    },

    // "Continue with Google" button (enable Google under Authentication → Providers)
    async signInWithGoogle() {
      return unwrap(await sb.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: location.origin + '/dashboard.html' },
      }));
    },

    async signOut() {
      localStorage.removeItem(BIZ_KEY);
      await sb.auth.signOut();
      location.href = 'login.html';
    },

    async profile() {
      const u = await Recorda.auth.user();
      const { data } = await sb.from('profiles').select('full_name, phone').eq('id', u.id).maybeSingle();
      return data || {};
    },

    async user() {
      const { data } = await sb.auth.getUser();
      return data.user;
    },

    // Put at the top of every private page (dashboard, products, ...).
    // Redirects to login if signed out, to onboarding if no business yet.
    // Returns { user, businessId }.
    async requireAuth() {
      const { data: { session } } = await sb.auth.getSession();
      if (!session) { location.href = 'login.html'; throw new Error('Not signed in'); }
      const businessId = await Recorda.business.currentId();
      if (!businessId) { location.href = 'onboarding.html'; throw new Error('No business yet'); }
      return { user: session.user, businessId };
    },

    // On login/register pages: skip ahead if already signed in
    async redirectIfSignedIn() {
      const { data: { session } } = await sb.auth.getSession();
      if (session) location.href = 'dashboard.html';
    },
  },

  // ---------- Business ----------
  business: {
    // onboarding.html (final step)
    async create({ name, type, tracking = [] }) {
      const id = unwrap(await sb.rpc('create_business', {
        p_name: name, p_type: type, p_tracking: tracking,
      }));
      localStorage.setItem(BIZ_KEY, id);
      return id;
    },

    // The business the user is working in (remembers the choice)
    async currentId() {
      const saved = localStorage.getItem(BIZ_KEY);
      if (saved) return saved;
      const rows = unwrap(await sb.from('business_members').select('business_id').limit(1));
      if (!rows.length) return null;
      localStorage.setItem(BIZ_KEY, rows[0].business_id);
      return rows[0].business_id;
    },

    async list() { // every business this user belongs to
      return unwrap(await sb.from('businesses').select('id, name, type').order('created_at'));
    },
    switchTo(id) {
      localStorage.setItem(BIZ_KEY, id);
      location.href = 'dashboard.html';
    },

    async get() {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('businesses').select('*').eq('id', id).single());
    },

    async update(fields) { // settings.html → Business → Edit
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('businesses').update(fields).eq('id', id).select().single());
    },

    // settings.html → Team
    async team() {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('business_members').select('user_id, role').eq('business_id', id));
    },
    async addMember(email, role = 'staff') {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.rpc('add_member_by_email', { p_business: id, p_email: email, p_role: role }));
    },
  },

  // ---------- Customers ----------
  customers: {
    async list(search = '') {
      const id = await Recorda.business.currentId();
      let q = sb.from('customers').select('*').eq('business_id', id).order('name');
      if (search) q = q.ilike('name', `%${search}%`);
      return unwrap(await q);
    },
    async add({ name, phone, address, notes }) {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('customers')
        .insert({ business_id: id, name, phone, address, notes }).select().single());
    },
    // customers.html: each customer + total purchases + outstanding balance
    async listWithStats() {
      const id = await Recorda.business.currentId();
      const [cust, bal, sales] = await Promise.all([
        sb.from('customers').select('*').eq('business_id', id).order('name'),
        sb.from('customer_balances').select('customer_id, balance, overdue').eq('business_id', id),
        sb.from('sales').select('customer_id, total').eq('business_id', id).not('customer_id', 'is', null),
      ]);
      const customers = unwrap(cust), balances = unwrap(bal), allSales = unwrap(sales);
      const balMap = Object.fromEntries(balances.map(b => [b.customer_id, b]));
      const spent = {};
      allSales.forEach(x => { spent[x.customer_id] = (spent[x.customer_id] || 0) + Number(x.total); });
      return customers.map(c => ({
        ...c,
        total_purchases: spent[c.id] || 0,
        balance: Number(balMap[c.id]?.balance || 0),
        overdue: !!balMap[c.id]?.overdue,
      }));
    },
    async get(customerId) { // customer-profile.html
      return unwrap(await sb.from('customers').select('*').eq('id', customerId).single());
    },
    async sales(customerId) {
      return unwrap(await sb.from('sales').select('*, sale_items(*)')
        .eq('customer_id', customerId).order('sale_date', { ascending: false }));
    },
  },

  // ---------- Products ----------
  products: {
    async list() {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('products').select('*').eq('business_id', id).order('name'));
    },
    async lowStock() {
      const all = await Recorda.products.list();
      return all.filter(p => p.quantity <= p.low_stock_threshold);
    },
    async get(productId) {
      return unwrap(await sb.from('products').select('*').eq('id', productId).single());
    },
    // add-product.html. imageFile is optional (an <input type="file"> File)
    async add({ name, category, buying_price, selling_price, quantity, low_stock_threshold, supplier, imageFile }) {
      const id = await Recorda.business.currentId();
      let image_url = null;
      if (imageFile) image_url = await Recorda.products.uploadImage(imageFile);
      return unwrap(await sb.from('products').insert({
        business_id: id, name, category, buying_price, selling_price,
        quantity, low_stock_threshold, supplier, image_url,
      }).select().single());
    },
    async update(productId, fields) {
      return unwrap(await sb.from('products').update(fields).eq('id', productId).select().single());
    },
    async remove(productId) {
      return unwrap(await sb.from('products').delete().eq('id', productId));
    },
    async uploadImage(file) {
      const id = await Recorda.business.currentId();
      const ext = file.name.split('.').pop();
      const path = `${id}/${crypto.randomUUID()}.${ext}`;   // folder = business id (matches storage policy)
      const { error } = await sb.storage.from('product-images').upload(path, file);
      if (error) throw new Error(error.message);
      return sb.storage.from('product-images').getPublicUrl(path).data.publicUrl;
    },
  },

  // ---------- Sales ----------
  sales: {
    // new-sale.html
    // items: [{ product_id (or null), name, qty, price }]
    // customerId: null for walk-in. paid: amount paid now (0 for full credit)
    async record({ customerId = null, items, discount = 0, method = 'Cash', paid = 0, date, dueDate = null }) {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.rpc('record_sale', {
        p_business: id, p_customer: customerId, p_items: items,
        p_discount: discount, p_method: method, p_paid: paid,
        p_date: date || new Date().toISOString().slice(0, 10), p_due: dueDate,
      })); // returns the new sale id → location.href = `receipt.html?id=${saleId}`
    },
    // receipt.html / transaction-detail.html
    async get(saleId) {
      return unwrap(await sb.from('sales')
        .select('*, customers(name, phone), sale_items(*)').eq('id', saleId).single());
    },
  },

  // ---------- Expenses ----------
  expenses: {
    async list(from, to) {
      const id = await Recorda.business.currentId();
      let q = sb.from('expenses').select('*').eq('business_id', id).order('expense_date', { ascending: false });
      if (from) q = q.gte('expense_date', from);
      if (to) q = q.lte('expense_date', to);
      return unwrap(await q);
    },
    // new-expense.html
    async add({ amount, category, description, method, date }) {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('expenses').insert({
        business_id: id, amount, category, description, payment_method: method,
        expense_date: date || new Date().toISOString().slice(0, 10),
      }).select().single());
    },
  },

  // ---------- Debts ----------
  debts: {
    // debts.html: everyone who owes, biggest first
    async list() {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('customer_balances').select('*')
        .eq('business_id', id).gt('balance', 0).order('balance', { ascending: false }));
    },
    // "Record Payment" button. Returns leftover (overpayment), normally 0
    async recordPayment({ customerId, amount, method = 'Cash', date }) {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.rpc('record_payment', {
        p_business: id, p_customer: customerId, p_amount: amount, p_method: method,
        p_date: date || new Date().toISOString().slice(0, 10),
      }));
    },
  },

  // ---------- Transactions & dashboard ----------
  transactions: {
    // transactions.html. kind: 'sale' | 'expense' | 'payment' | undefined for all
    async list({ kind, limit = 50 } = {}) {
      const id = await Recorda.business.currentId();
      let q = sb.from('transactions').select('*').eq('business_id', id)
        .order('txn_date', { ascending: false }).order('created_at', { ascending: false }).limit(limit);
      if (kind) q = q.eq('kind', kind);
      return unwrap(await q);
    },
  },

  dashboard: {
    // dashboard.html / reports.html. from & to are 'YYYY-MM-DD'
    async summary(from, to) {
      const id = await Recorda.business.currentId();
      const s = unwrap(await sb.rpc('dashboard_summary', { p_business: id, p_from: from, p_to: to }));
      s.profit = s.sales_total - s.expenses_total;
      return s;
    },
  },

  // ---------- Custom records ----------
  records: {
    async types() { // records.html
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('record_types').select('*').eq('business_id', id).order('created_at'));
    },
    // create-record-type.html
    // fields: [{ label:'Plate Number', type:'Text', options:[] }, ...]
    async createType({ name, description, fields }) {
      const id = await Recorda.business.currentId();
      const withKeys = fields.map(f => ({
        key: f.label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''),
        label: f.label, type: f.type, options: f.options || [],
      }));
      return unwrap(await sb.from('record_types')
        .insert({ business_id: id, name, description, fields: withKeys }).select().single());
    },
    async entries(typeId) { // custom-record-list.html
      return unwrap(await sb.from('record_entries').select('*')
        .eq('record_type_id', typeId).order('created_at', { ascending: false }));
    },
    // data = { plate_number:'ABC-123-KD', driver:'Musa', ... } keyed by field key
    async addEntry(typeId, data) {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('record_entries')
        .insert({ business_id: id, record_type_id: typeId, data }).select().single());
    },
    async updateEntry(entryId, data) {
      return unwrap(await sb.from('record_entries').update({ data }).eq('id', entryId).select().single());
    },
    async removeEntry(entryId) {
      return unwrap(await sb.from('record_entries').delete().eq('id', entryId));
    },
  },

  // ---------- Notifications ----------
  notifications: {
    async list() {
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('notifications').select('*')
        .eq('business_id', id).order('created_at', { ascending: false }).limit(50));
    },
    async markAllRead() { // markAllRead() on notifications.html
      const id = await Recorda.business.currentId();
      return unwrap(await sb.from('notifications').update({ is_read: true })
        .eq('business_id', id).eq('is_read', false));
    },
  },

  // ---------- Small utilities ----------
  util: {
    esc(str) {
      return String(str ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    },
    initials(name) {
      const p = String(name || '?').trim().split(/\s+/);
      return ((p[0]?.[0] || '') + (p.length > 1 ? p[p.length - 1][0] : '')).toUpperCase();
    },
    // rotating avatar colours (same palette as the design)
    avatarStyle(i) {
      return ['', 'background:var(--amber-tint); color:var(--amber);', 'background:var(--blue-tint); color:var(--blue);',
              'background:var(--red-tint); color:var(--red);'][i % 4];
    },
    prettyDate(d) {
      return d ? new Date(d + 'T00:00:00').toLocaleDateString('en-NG', { year: 'numeric', month: 'short', day: 'numeric' }) : '';
    },
    naira(n) {
      return '₦' + Number(n || 0).toLocaleString('en-NG', { maximumFractionDigits: 2 });
    },
    // 0802 345 6789 → 2348023456789
    intlPhone(phone) {
      const d = String(phone || '').replace(/\D/g, '');
      return d.startsWith('0') ? '234' + d.slice(1) : d;
    },
    // "Share on WhatsApp" / "Remind" buttons
    whatsappLink(phone, text) {
      return `https://wa.me/${Recorda.util.intlPhone(phone)}?text=${encodeURIComponent(text)}`;
    },
  },
};

window.Recorda = Recorda;

/* ---------- Usage examples ----------

// register.html
form.onsubmit = async (e) => {
  e.preventDefault();
  try {
    await Recorda.auth.signUp({ name: name.value, email: email.value, phone: phone.value, password: pw.value });
    location.href = 'onboarding.html';
  } catch (err) { showToast(err.message); }
};

// dashboard.html (top of page)
const { businessId } = await Recorda.auth.requireAuth();
const today = new Date().toISOString().slice(0, 10);
const s = await Recorda.dashboard.summary(today.slice(0, 8) + '01', today);
// s.sales_total, s.expenses_total, s.profit, s.outstanding_debt, s.low_stock_count

// new-sale.html → Record Sale
const saleId = await Recorda.sales.record({
  customerId: null,
  items: [{ product_id: null, name: 'Native Shirt', qty: 2, price: 20000 }],
  discount: 0, method: 'Cash', paid: 40000,
});
location.href = 'receipt.html?id=' + saleId;

// debts.html → Remind
location.href = Recorda.util.whatsappLink(c.phone,
  `Hi ${c.name}, a friendly reminder of your balance of ${Recorda.util.naira(c.balance)}.`);
*/
