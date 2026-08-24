/* Brown Enterprises · configurazione condivisa area riservata */
window.BE_CONFIG = {
  supabaseUrl: "https://api.fosforo.info",
  supabaseAnonKey: "sb_publishable_U5-k5ljKyv3Edwlyt3brS5_0DLCA7Kq",
  knownPersons: ["Alessandro", "Luca", "Lorenzo", "Valeria", "Mattia", "Camilla"]
};

window.beEmailForName = function (name) {
  return String(name || "").trim().toLowerCase() + "@brown.internal";
};

window.beClient = window.supabase.createClient(
  window.BE_CONFIG.supabaseUrl,
  window.BE_CONFIG.supabaseAnonKey
);
