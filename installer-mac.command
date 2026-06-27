#!/bin/bash
# ============================================================================
#  Cabinet kiné — installateur macOS (double-cliquable)
#  Crée ~/cabinet-kine et un lanceur « demarrer.command » double-cliquable.
#  N'a pas besoin de Homebrew : utilise Python 3 des outils Apple.
# ============================================================================
cd "$HOME" || exit 1
info(){ echo "  $1"; }

echo ""
echo "  Installation du Cabinet kine (macOS)..."
echo ""

# 1) Python 3 (outils de developpement Apple, sans Homebrew)
if ! command -v python3 >/dev/null 2>&1; then
  echo "  Python 3 n'est pas encore installe."
  echo "  Une fenetre Apple va proposer d'installer les outils de developpement."
  echo "  -> Cliquez sur « Installer », attendez la fin, puis RELANCEZ ce fichier."
  xcode-select --install 2>/dev/null
  echo ""
  echo "  (Appuyez sur Entree pour fermer cette fenetre.)"
  read -r _
  exit 0
fi

APP="$HOME/cabinet-kine"
mkdir -p "$APP/templates" "$APP/static"

# 2) Environnement Python isole + dependances
info "Preparation de l'environnement Python..."
python3 -m venv "$APP/venv" || { echo "  Echec de creation de l'environnement."; read -r _; exit 1; }
source "$APP/venv/bin/activate"
pip install --upgrade pip >/dev/null 2>&1
info "Installation de Flask, reportlab (PDF) et cryptography (HTTPS)..."
pip install flask reportlab cryptography || { echo "  Echec d'installation des dependances."; read -r _; exit 1; }

# 3) Fichiers de l'application
info "Ecriture des fichiers de l'application..."
info "  · app.py"
cat > "$APP/app.py" << '__FIN_APP_PY__'
#!/usr/bin/env python3
"""Cabinet kiné — socle de gestion (espace kiné uniquement).

Application web LOCALE pour un cabinet de kinésithérapie :
  - dossiers patients (pathologie, objectifs court/long terme, note libre),
  - calendrier par patient avec annotation des séances,
  - niveau de douleur (EVA 1-10) par séance + graphique d'évolution.

Tout reste sur la machine : base SQLite locale, aucun envoi en ligne.
Sert une interface sur http://127.0.0.1:5001
"""
import os
import io
import sqlite3
import secrets
import tempfile
import random
import calendar
import re
import socket
from datetime import datetime, date, timedelta, timezone
from functools import wraps

from flask import (
    Flask, request, session, redirect, url_for,
    render_template, jsonify, abort, flash, g, send_file,
)
from werkzeug.security import generate_password_hash, check_password_hash

ICI = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(ICI, "cabinet.db")
SECRET_FILE = os.path.join(ICI, ".secret")

# Le module de transcription vocale est optionnel (installé séparément).
try:
    import transcription
    import resume
    AUDIO_DISPO = True
except Exception:
    AUDIO_DISPO = False


def cle_secrete():
    """Clé de session persistante (pour rester connecté entre redémarrages)."""
    if os.path.exists(SECRET_FILE):
        with open(SECRET_FILE) as f:
            return f.read().strip()
    cle = secrets.token_hex(32)
    with open(SECRET_FILE, "w") as f:
        f.write(cle)
    os.chmod(SECRET_FILE, 0o600)
    return cle


app = Flask(__name__)
app.secret_key = cle_secrete()


# --------------------------------------------------------------------------
#  Base de données
# --------------------------------------------------------------------------
def co():
    if "db" not in g:
        g.db = sqlite3.connect(DB)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")
    return g.db


@app.teardown_appcontext
def fermer_db(_exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


ADMIN_DEFAUT_ID = "admin"
ADMIN_DEFAUT_MDP = "admin"
QUESTION_DEFAUT = "Quelle est la marque de ma première voiture ?"
REPONSE_DEFAUT = "citroen"


def init_db():
    db = sqlite3.connect(DB)
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS kine (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            identifiant TEXT UNIQUE NOT NULL,
            mdp_hash    TEXT NOT NULL,
            cree_le     TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS patients (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            prenom          TEXT NOT NULL,
            nom             TEXT NOT NULL,
            naissance       TEXT,
            pathologie      TEXT,
            objectif_court  TEXT,
            objectif_long   TEXT,
            note_libre      TEXT,
            archive         INTEGER NOT NULL DEFAULT 0,
            cree_le         TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS seances (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            patient_id  INTEGER NOT NULL,
            date_seance TEXT NOT NULL,
            heure       TEXT,
            fait        TEXT,
            douleur     INTEGER,
            cree_le     TEXT NOT NULL,
            UNIQUE(patient_id, date_seance),
            FOREIGN KEY(patient_id) REFERENCES patients(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS praticiens (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            nom     TEXT UNIQUE NOT NULL,
            cree_le TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS config (
            cle    TEXT PRIMARY KEY,
            valeur TEXT
        );
        """
    )
    db.commit()
    # Migration : marqueur des patients de démonstration
    cols = [r[1] for r in db.execute("PRAGMA table_info(patients)").fetchall()]
    if "demo" not in cols:
        db.execute("ALTER TABLE patients ADD COLUMN demo INTEGER NOT NULL DEFAULT 0")
        db.commit()
    # Migration : heure des séances (créneaux)
    cols_s = [r[1] for r in db.execute("PRAGMA table_info(seances)").fetchall()]
    if "heure" not in cols_s:
        db.execute("ALTER TABLE seances ADD COLUMN heure TEXT")
        db.commit()
    if "praticien" not in cols_s:
        db.execute("ALTER TABLE seances ADD COLUMN praticien TEXT")
        db.commit()
    # Migration : rôle des comptes
    cols_k = [r[1] for r in db.execute("PRAGMA table_info(kine)").fetchall()]
    if "role" not in cols_k:
        db.execute("ALTER TABLE kine ADD COLUMN role TEXT NOT NULL DEFAULT 'praticien'")
        db.commit()
    if "question" not in cols_k:
        db.execute("ALTER TABLE kine ADD COLUMN question TEXT")
        db.commit()
    if "reponse_hash" not in cols_k:
        db.execute("ALTER TABLE kine ADD COLUMN reponse_hash TEXT")
        db.commit()
    # Compte administrateur par défaut : garanti tant que son mot de passe
    # est encore celui par défaut (sinon on respecte le mot de passe choisi).
    rep_def = generate_password_hash(REPONSE_DEFAUT.strip().upper())
    admin = db.execute(
        "SELECT mdp_hash FROM kine WHERE identifiant = ?", (ADMIN_DEFAUT_ID,)
    ).fetchone()
    if admin is None:
        db.execute(
            "INSERT INTO kine (identifiant, mdp_hash, role, question, reponse_hash, cree_le) "
            "VALUES (?,?,?,?,?,?)",
            (ADMIN_DEFAUT_ID, generate_password_hash(ADMIN_DEFAUT_MDP), "admin",
             QUESTION_DEFAUT, rep_def, datetime.now().isoformat(timespec="seconds")),
        )
        db.commit()
    elif check_password_hash(admin[0], ADMIN_DEFAUT_MDP):
        db.execute(
            "UPDATE kine SET role = 'admin', question = ?, reponse_hash = ? "
            "WHERE identifiant = ?",
            (QUESTION_DEFAUT, rep_def, ADMIN_DEFAUT_ID),
        )
        db.commit()
    # Un seul administrateur : tout autre compte est un praticien
    db.execute(
        "UPDATE kine SET role = 'praticien' WHERE identifiant <> ? AND role = 'admin'",
        (ADMIN_DEFAUT_ID,),
    )
    db.commit()
    db.close()


def normaliser_heure(v):
    """Renvoie 'HH:00' ou 'HH:30' (créneaux de 30 min), ou None."""
    v = (v or "").strip()
    if not v:
        return None
    try:
        parts = v.split(":")
        h, m = int(parts[0]), int(parts[1])
        if 0 <= h <= 23:
            return "%02d:%02d" % (h, 0 if m < 30 else 30)
    except (ValueError, IndexError):
        pass
    return None


PALETTE_PRAT = ["#5A4FE3", "#1F9D6B", "#E0A100", "#2563EB", "#D6409F",
                "#0E8FA8", "#C2410C", "#7C3AED"]


def liste_praticiens():
    return [r["identifiant"] for r in co().execute(
        "SELECT identifiant FROM kine WHERE role = 'praticien' ORDER BY id"
    ).fetchall()]


def praticiens_couleurs():
    rows = co().execute(
        "SELECT id, identifiant FROM kine WHERE role = 'praticien' ORDER BY id"
    ).fetchall()
    return {r["identifiant"]: PALETTE_PRAT[(r["id"] - 1) % len(PALETTE_PRAT)] for r in rows}


def praticien_valide(v):
    v = (v or "").strip()
    return v if v in liste_praticiens() else None


# -- Administration (réservée au compte de rôle « admin ») --
def est_admin():
    return bool(session.get("est_admin"))


def _norm_reponse(v):
    return (v or "").strip().upper()


def admin_requise(vue):
    @wraps(vue)
    def wrap(*a, **kw):
        if not session.get("kine_id"):
            return redirect(url_for("connexion"))
        if not est_admin():
            flash("Cette section est réservée à l'administrateur.")
            return redirect(url_for("dashboard"))
        return vue(*a, **kw)
    return wrap


def maintenant():
    return datetime.now().isoformat(timespec="seconds")


# --------------------------------------------------------------------------
#  Authentification
# --------------------------------------------------------------------------
def compte_existe():
    return co().execute("SELECT 1 FROM kine LIMIT 1").fetchone() is not None


def connexion_requise(vue):
    @wraps(vue)
    def wrap(*a, **kw):
        if not session.get("kine_id"):
            return redirect(url_for("connexion"))
        return vue(*a, **kw)
    return wrap


@app.route("/")
def accueil():
    if not compte_existe():
        return redirect(url_for("setup"))
    if not session.get("kine_id"):
        return redirect(url_for("connexion"))
    return redirect(url_for("dashboard"))


@app.route("/bienvenue", methods=["GET", "POST"])
def setup():
    """Création du premier (et unique) compte kiné. Pas de mot de passe par défaut."""
    if compte_existe():
        return redirect(url_for("connexion"))
    if request.method == "POST":
        ident = (request.form.get("identifiant") or "").strip()
        mdp = request.form.get("mdp") or ""
        mdp2 = request.form.get("mdp2") or ""
        question = (request.form.get("question") or "").strip()
        reponse = (request.form.get("reponse") or "").strip()
        if len(ident) < 3:
            flash("L'identifiant doit faire au moins 3 caractères.")
        elif len(mdp) < 6:
            flash("Le mot de passe doit faire au moins 6 caractères.")
        elif mdp != mdp2:
            flash("Les deux mots de passe ne correspondent pas.")
        elif not question or not reponse:
            flash("Veuillez renseigner la question de sécurité et sa réponse.")
        else:
            co().execute(
                "INSERT INTO kine (identifiant, mdp_hash, role, question, reponse_hash, cree_le) "
                "VALUES (?,?,?,?,?,?)",
                (ident, generate_password_hash(mdp), "admin", question,
                 generate_password_hash(_norm_reponse(reponse)), maintenant()),
            )
            co().commit()
            ligne = co().execute(
                "SELECT id FROM kine WHERE identifiant = ?", (ident,)
            ).fetchone()
            session["kine_id"] = ligne["id"]
            session["est_admin"] = True
            return redirect(url_for("dashboard"))
    return render_template("setup.html")


@app.route("/connexion", methods=["GET", "POST"])
def connexion():
    if not compte_existe():
        return redirect(url_for("setup"))
    if request.method == "POST":
        ident = (request.form.get("identifiant") or "").strip()
        mdp = request.form.get("mdp") or ""
        ligne = co().execute(
            "SELECT * FROM kine WHERE identifiant = ?", (ident,)
        ).fetchone()
        if ligne and check_password_hash(ligne["mdp_hash"], mdp):
            session["kine_id"] = ligne["id"]
            session["est_admin"] = (ligne["role"] == "admin")
            return redirect(url_for("dashboard"))
        flash("Identifiant ou mot de passe incorrect.")
    return render_template("connexion.html")


@app.route("/deconnexion")
def deconnexion():
    session.clear()
    return redirect(url_for("connexion"))


@app.route("/mot-de-passe-oublie", methods=["GET", "POST"])
def mdp_oublie():
    if not compte_existe():
        return redirect(url_for("setup"))
    if request.method == "POST":
        ident = (request.form.get("identifiant") or "").strip()
        compte = co().execute(
            "SELECT * FROM kine WHERE identifiant = ?", (ident,)
        ).fetchone()
        if not compte or not compte["question"] or not compte["reponse_hash"]:
            flash("Aucune question de sécurité n'est configurée pour cet identifiant.")
            return render_template("mdp_oublie.html", etape=1)
        # Étape 2 : la réponse et le nouveau mot de passe sont fournis
        if "reponse" in request.form:
            if not check_password_hash(compte["reponse_hash"],
                                       _norm_reponse(request.form.get("reponse"))):
                flash("Réponse incorrecte.")
            else:
                mdp = request.form.get("mdp") or ""
                mdp2 = request.form.get("mdp2") or ""
                if len(mdp) < 6:
                    flash("Le mot de passe doit faire au moins 6 caractères.")
                elif mdp != mdp2:
                    flash("Les deux mots de passe ne correspondent pas.")
                else:
                    co().execute("UPDATE kine SET mdp_hash = ? WHERE id = ?",
                                 (generate_password_hash(mdp), compte["id"]))
                    co().commit()
                    flash("Mot de passe réinitialisé. Vous pouvez vous connecter.")
                    return redirect(url_for("connexion"))
            return render_template("mdp_oublie.html", etape=2, identifiant=ident,
                                   question=compte["question"])
        # Étape 1 -> 2 : afficher la question de ce compte
        return render_template("mdp_oublie.html", etape=2, identifiant=ident,
                               question=compte["question"])
    return render_template("mdp_oublie.html", etape=1)


@app.route("/securite", methods=["GET", "POST"])
@connexion_requise
def securite():
    compte = co().execute(
        "SELECT * FROM kine WHERE id = ?", (session["kine_id"],)
    ).fetchone()
    if request.method == "POST":
        action = request.form.get("action")
        if action == "mdp":
            ancien = request.form.get("ancien") or ""
            mdp = request.form.get("mdp") or ""
            mdp2 = request.form.get("mdp2") or ""
            if not check_password_hash(compte["mdp_hash"], ancien):
                flash("Mot de passe actuel incorrect.")
            elif len(mdp) < 6:
                flash("Le nouveau mot de passe doit faire au moins 6 caractères.")
            elif mdp != mdp2:
                flash("Les deux mots de passe ne correspondent pas.")
            else:
                co().execute("UPDATE kine SET mdp_hash = ? WHERE id = ?",
                             (generate_password_hash(mdp), compte["id"]))
                co().commit()
                flash("Mot de passe modifié.")
        elif action == "question":
            question = (request.form.get("question") or "").strip()
            reponse = (request.form.get("reponse") or "").strip()
            if not question or not reponse:
                flash("Question et réponse sont requises.")
            else:
                co().execute("UPDATE kine SET question = ?, reponse_hash = ? WHERE id = ?",
                             (question, generate_password_hash(_norm_reponse(reponse)),
                              compte["id"]))
                co().commit()
                flash("Question de sécurité enregistrée.")
        return redirect(url_for("securite"))
    return render_template("securite.html", compte=compte)


# --------------------------------------------------------------------------
#  Tableau de bord
# --------------------------------------------------------------------------
@app.route("/dashboard")
@connexion_requise
def dashboard():
    patients = co().execute(
        """
        SELECT p.*,
               (SELECT COUNT(*) FROM seances s WHERE s.patient_id = p.id) AS nb_seances,
               (SELECT MAX(date_seance) FROM seances s WHERE s.patient_id = p.id) AS derniere,
               (SELECT douleur FROM seances s WHERE s.patient_id = p.id
                  AND douleur IS NOT NULL ORDER BY date_seance DESC LIMIT 1) AS douleur_recente
        FROM patients p
        WHERE p.archive = 0
        ORDER BY p.nom COLLATE NOCASE, p.prenom COLLATE NOCASE
        """
    ).fetchall()
    nb_archives = co().execute(
        "SELECT COUNT(*) AS n FROM patients WHERE archive = 1"
    ).fetchone()["n"]
    return render_template("dashboard.html", patients=patients, nb_archives=nb_archives)


@app.route("/archives")
@connexion_requise
def archives():
    patients = co().execute(
        "SELECT * FROM patients WHERE archive = 1 ORDER BY nom COLLATE NOCASE"
    ).fetchall()
    return render_template("archives.html", patients=patients)


@app.route("/calendrier")
@connexion_requise
def calendrier():
    return render_template("calendrier.html")


@app.route("/agenda.json")
@connexion_requise
def agenda_json():
    lignes = co().execute(
        """SELECT s.date_seance, s.heure, s.douleur, s.fait, s.praticien,
                  p.id AS patient_id, p.prenom, p.nom, p.archive
           FROM seances s JOIN patients p ON p.id = s.patient_id
           ORDER BY s.date_seance, s.heure IS NULL, s.heure,
                    p.nom COLLATE NOCASE, p.prenom COLLATE NOCASE"""
    ).fetchall()
    return jsonify([dict(x) for x in lignes])


@app.route("/patients.json")
@connexion_requise
def patients_json():
    rows = co().execute(
        "SELECT id, prenom, nom FROM patients WHERE archive = 0 "
        "ORDER BY nom COLLATE NOCASE, prenom COLLATE NOCASE"
    ).fetchall()
    return jsonify([dict(r) for r in rows])


# --------------------------------------------------------------------------
#  Dossiers patients
# --------------------------------------------------------------------------
def get_patient(pid):
    p = co().execute("SELECT * FROM patients WHERE id = ?", (pid,)).fetchone()
    if p is None:
        abort(404)
    return p


@app.route("/patient/nouveau", methods=["GET", "POST"])
@connexion_requise
def patient_nouveau():
    if request.method == "POST":
        prenom = (request.form.get("prenom") or "").strip()
        nom = (request.form.get("nom") or "").strip()
        if not prenom or not nom:
            flash("Le prénom et le nom sont obligatoires.")
            return render_template("patient_form.html", patient=request.form, mode="nouveau")
        cur = co().execute(
            """INSERT INTO patients
               (prenom, nom, naissance, pathologie, objectif_court, objectif_long,
                note_libre, cree_le)
               VALUES (?,?,?,?,?,?,?,?)""",
            (
                prenom, nom,
                request.form.get("naissance") or None,
                request.form.get("pathologie") or None,
                request.form.get("objectif_court") or None,
                request.form.get("objectif_long") or None,
                request.form.get("note_libre") or None,
                maintenant(),
            ),
        )
        co().commit()
        return redirect(url_for("patient", pid=cur.lastrowid))
    return render_template("patient_form.html", patient={}, mode="nouveau")


@app.route("/patient/<int:pid>")
@connexion_requise
def patient(pid):
    p = get_patient(pid)
    seances = co().execute(
        "SELECT * FROM seances WHERE patient_id = ? ORDER BY date_seance DESC", (pid,)
    ).fetchall()
    return render_template("patient.html", p=p, seances=seances)


@app.route("/patient/<int:pid>/modifier", methods=["GET", "POST"])
@connexion_requise
def patient_modifier(pid):
    p = get_patient(pid)
    if request.method == "POST":
        prenom = (request.form.get("prenom") or "").strip()
        nom = (request.form.get("nom") or "").strip()
        if not prenom or not nom:
            flash("Le prénom et le nom sont obligatoires.")
            return render_template("patient_form.html", patient=request.form, mode="modifier")
        co().execute(
            """UPDATE patients SET prenom=?, nom=?, naissance=?, pathologie=?,
               objectif_court=?, objectif_long=?, note_libre=? WHERE id=?""",
            (
                prenom, nom,
                request.form.get("naissance") or None,
                request.form.get("pathologie") or None,
                request.form.get("objectif_court") or None,
                request.form.get("objectif_long") or None,
                request.form.get("note_libre") or None,
                pid,
            ),
        )
        co().commit()
        return redirect(url_for("patient", pid=pid))
    return render_template("patient_form.html", patient=p, mode="modifier")


@app.route("/patient/<int:pid>/note", methods=["POST"])
@connexion_requise
def patient_note(pid):
    get_patient(pid)
    co().execute(
        "UPDATE patients SET note_libre = ? WHERE id = ?",
        (request.form.get("note_libre") or None, pid),
    )
    co().commit()
    return redirect(url_for("patient", pid=pid))


@app.route("/patient/<int:pid>/archiver", methods=["POST"])
@connexion_requise
def patient_archiver(pid):
    get_patient(pid)
    co().execute("UPDATE patients SET archive = 1 WHERE id = ?", (pid,))
    co().commit()
    flash("Patient archivé.")
    return redirect(url_for("dashboard"))


@app.route("/patient/<int:pid>/restaurer", methods=["POST"])
@connexion_requise
def patient_restaurer(pid):
    get_patient(pid)
    co().execute("UPDATE patients SET archive = 0 WHERE id = ?", (pid,))
    co().commit()
    return redirect(url_for("patient", pid=pid))


# --------------------------------------------------------------------------
#  Séances (annotation depuis le calendrier + douleur)
# --------------------------------------------------------------------------
@app.route("/patient/<int:pid>/seance", methods=["POST"])
@connexion_requise
def seance_enregistrer(pid):
    get_patient(pid)
    date_seance = (request.form.get("date_seance") or "").strip()
    if not date_seance:
        abort(400)
    fait = request.form.get("fait") or None
    douleur_brut = request.form.get("douleur")
    douleur = None
    if douleur_brut not in (None, "", "0"):
        try:
            d = int(douleur_brut)
            if 1 <= d <= 10:
                douleur = d
        except ValueError:
            douleur = None
    # heure et praticien : modifiés uniquement s'ils sont explicitement envoyés
    # (permet de les changer/vider depuis la modale sans casser le bilan oral)
    maj_heure = "heure" in request.form
    maj_prat = "praticien" in request.form
    heure = normaliser_heure(request.form.get("heure")) if maj_heure else None
    prat = praticien_valide(request.form.get("praticien")) if maj_prat else None
    db = co()
    db.execute(
        """INSERT INTO seances (patient_id, date_seance, heure, praticien, fait, douleur, cree_le)
           VALUES (?,?,?,?,?,?,?)
           ON CONFLICT(patient_id, date_seance)
           DO UPDATE SET fait=excluded.fait, douleur=excluded.douleur""",
        (pid, date_seance, heure, prat, fait, douleur, maintenant()),
    )
    if maj_heure:
        db.execute("UPDATE seances SET heure=? WHERE patient_id=? AND date_seance=?",
                   (heure, pid, date_seance))
    if maj_prat:
        db.execute("UPDATE seances SET praticien=? WHERE patient_id=? AND date_seance=?",
                   (prat, pid, date_seance))
    db.commit()
    if request.form.get("ajax"):
        return jsonify({"ok": True})
    return redirect(url_for("patient", pid=pid) + "#seances")


@app.route("/patient/<int:pid>/creneau", methods=["POST"])
@connexion_requise
def creneau_enregistrer(pid):
    """Assigne un patient à un créneau (date + heure) sans toucher au compte-rendu."""
    get_patient(pid)
    date_seance = (request.form.get("date") or "").strip()
    heure = normaliser_heure(request.form.get("heure"))
    prat = praticien_valide(request.form.get("praticien"))
    if not date_seance or not heure:
        abort(400)
    co().execute(
        """INSERT INTO seances (patient_id, date_seance, heure, praticien, cree_le)
           VALUES (?,?,?,?,?)
           ON CONFLICT(patient_id, date_seance)
           DO UPDATE SET heure=excluded.heure, praticien=excluded.praticien""",
        (pid, date_seance, heure, prat, maintenant()),
    )
    co().commit()
    return jsonify({"ok": True})


@app.route("/patient/<int:pid>/seance/<int:sid>/supprimer", methods=["POST"])
@connexion_requise
def seance_supprimer(pid, sid):
    get_patient(pid)
    co().execute("DELETE FROM seances WHERE id = ? AND patient_id = ?", (sid, pid))
    co().commit()
    return redirect(url_for("patient", pid=pid) + "#seances")


@app.route("/patient/<int:pid>/seances.json")
@connexion_requise
def seances_json(pid):
    get_patient(pid)
    lignes = co().execute(
        "SELECT id, date_seance, heure, praticien, fait, douleur FROM seances WHERE patient_id = ? ORDER BY date_seance",
        (pid,),
    ).fetchall()
    return jsonify([dict(x) for x in lignes])


@app.route("/patient/<int:pid>/pdf")
@connexion_requise
def patient_pdf(pid):
    p = get_patient(pid)
    seances = co().execute(
        "SELECT * FROM seances WHERE patient_id = ? ORDER BY date_seance", (pid,)
    ).fetchall()
    try:
        import pdf_export
    except Exception:
        abort(500, "Export PDF indisponible (reportlab non installé).")
    data = pdf_export.generer_fiche(dict(p), [dict(s) for s in seances])
    base = "bilan_%s_%s" % (p["nom"], p["prenom"])
    nom = "".join(c if (c.isalnum() or c in "-_") else "_" for c in base) + ".pdf"
    return send_file(io.BytesIO(data), mimetype="application/pdf",
                     as_attachment=True, download_name=nom)


@app.route("/reformuler", methods=["POST"])
@connexion_requise
def reformuler():
    """Réécrit un texte de séance via le modèle local (clarté/orthographe)."""
    if not AUDIO_DISPO:
        return jsonify({"erreur": "Module IA non installé."}), 400
    res = resume.reformuler(request.form.get("texte", ""))
    return jsonify(res)


@app.route("/patient/<int:pid>/bilan", methods=["POST"])
@connexion_requise
def bilan_oral(pid):
    """Reçoit la dictée, transcrit en local puis résume. Rien n'est envoyé en ligne."""
    if not AUDIO_DISPO:
        return jsonify({"erreur": "Module audio non installé."}), 400
    get_patient(pid)
    if "audio" not in request.files:
        return jsonify({"erreur": "Aucun audio reçu."}), 400
    fichier = request.files["audio"]
    suffixe = os.path.splitext(fichier.filename or "")[1] or ".webm"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffixe) as tmp:
        fichier.save(tmp.name)
        chemin = tmp.name
    try:
        tr = transcription.transcrire(chemin)
        texte = tr.get("texte", "")
        res = resume.resumer(texte)
        return jsonify({
            "transcription": texte,
            "resume": res.get("resume", ""),
            "moteur": res.get("moteur", ""),
            "douleur": resume.detecter_douleur(texte),
            "duree": tr.get("duree"),
        })
    except Exception as e:  # noqa: BLE001
        return jsonify({"erreur": str(e)}), 500
    finally:
        try:
            os.remove(chemin)
        except OSError:
            pass


# --------------------------------------------------------------------------
#  Données de test (patients fictifs, marqués demo=1, supprimables)
# --------------------------------------------------------------------------
_PRENOMS = ["Marie", "Jean", "Sophie", "Luc", "Alice", "Paul", "Emma", "Thomas",
            "Julie", "Pierre", "Camille", "Nicolas", "Léa", "Hugo", "Chloé",
            "Antoine", "Manon", "Louis", "Sarah", "Maxime", "Inès", "Théo",
            "Clara", "Lucas", "Eva", "Nathan", "Jade", "Gabriel", "Lola", "Adam"]
_NOMS = ["Durand", "Petit", "Martin", "Bernard", "Dubois", "Moreau", "Laurent",
         "Simon", "Michel", "Lefebvre", "Garcia", "Roux", "Fontaine", "Girard",
         "Bonnet", "Dupont", "Lambert", "Rousseau", "Vincent", "Muller", "Faure",
         "André", "Mercier", "Blanc", "Guérin", "Boyer", "Garnier", "Chevalier"]
_PATHOS = ["Lombalgie chronique", "Tendinopathie de l'épaule", "Entorse de la cheville",
           "Rééducation post-prothèse de genou", "Cervicalgie", "Syndrome rotulien",
           "Capsulite rétractile", "Lombosciatique", "Rupture du LCA (post-op)",
           "Périarthrite scapulo-humérale"]
_ACTES = ["Mobilisations passives et actives.", "Renforcement musculaire progressif.",
          "Étirements et travail proprioceptif.", "Massage décontracturant et physiothérapie.",
          "Travail de l'équilibre et de la marche.", "Exercices de gainage.",
          "Rééducation fonctionnelle.", "Travail excentrique progressif."]
_OBJ_C = ["Réduire la douleur sous 3 semaines.", "Récupérer l'amplitude articulaire.",
          "Diminuer l'inflammation.", "Reprendre la marche sans canne."]
_OBJ_L = ["Reprise du sport sans appréhension.", "Retour au travail.",
          "Autonomie complète au quotidien.", "Prévention des récidives."]


def _creer_patient_demo(db):
    cur = db.execute(
        """INSERT INTO patients
           (prenom, nom, naissance, pathologie, objectif_court, objectif_long,
            note_libre, demo, cree_le)
           VALUES (?,?,?,?,?,?,?,1,?)""",
        (random.choice(_PRENOMS), random.choice(_NOMS), None,
         random.choice(_PATHOS), random.choice(_OBJ_C), random.choice(_OBJ_L),
         "[Données de démonstration]", maintenant()),
    )
    return cur.lastrowid


def _heure_creneau_demo():
    """Heure de créneau aléatoire alignée sur :00/:30, entre 07:00 et 19:30."""
    m = random.randrange(7 * 60, 20 * 60, 30)
    return "%02d:%02d" % (m // 60, m % 60)


def _ajouter_seance_demo(db, pid, jour_iso, prats):
    db.execute(
        "INSERT INTO seances (patient_id, date_seance, heure, praticien, fait, douleur, cree_le) "
        "VALUES (?,?,?,?,?,?,?)",
        (pid, jour_iso, _heure_creneau_demo(), (random.choice(prats) if prats else None),
         random.choice(_ACTES), random.randint(1, 10), maintenant()),
    )


# --------------------------------------------------------------------------
#  Administration (réservée au compte admin) : comptes, praticiens, démo
# --------------------------------------------------------------------------
@app.route("/admin")
@admin_requise
def admin_panel():
    comptes = co().execute(
        "SELECT id, identifiant, role FROM kine ORDER BY role DESC, identifiant COLLATE NOCASE"
    ).fetchall()
    nb_demo = co().execute(
        "SELECT COUNT(*) AS n FROM patients WHERE demo = 1"
    ).fetchone()["n"]
    return render_template("admin_panel.html", comptes=comptes,
                           couleurs=praticiens_couleurs(),
                           nb_demo=nb_demo, aujourdhui=date.today().isoformat(),
                           moi=session.get("kine_id"))


@app.route("/admin/comptes/ajouter", methods=["POST"])
@admin_requise
def admin_compte_ajouter():
    ident = (request.form.get("identifiant") or "").strip()
    mdp = request.form.get("mdp") or ""
    if len(ident) < 3 or len(ident) > 40:
        flash("Le nom/identifiant doit faire entre 3 et 40 caractères.")
    elif len(mdp) < 6:
        flash("Le mot de passe doit faire au moins 6 caractères.")
    else:
        try:
            co().execute(
                "INSERT INTO kine (identifiant, mdp_hash, role, cree_le) VALUES (?,?,?,?)",
                (ident, generate_password_hash(mdp), "praticien", maintenant()),
            )
            co().commit()
            flash("Praticien « %s » ajouté (il peut se connecter avec ce nom)." % ident)
        except sqlite3.IntegrityError:
            flash("Ce nom/identifiant existe déjà.")
    return redirect(url_for("admin_panel") + "#praticiens")


@app.route("/admin/comptes/<int:compte_id>/supprimer", methods=["POST"])
@admin_requise
def admin_compte_supprimer(compte_id):
    if compte_id == session.get("kine_id"):
        flash("Vous ne pouvez pas supprimer votre propre compte.")
        return redirect(url_for("admin_panel") + "#praticiens")
    row = co().execute("SELECT role FROM kine WHERE id = ?", (compte_id,)).fetchone()
    if row and row["role"] == "admin":
        flash("Le compte administrateur ne peut pas être supprimé.")
        return redirect(url_for("admin_panel") + "#praticiens")
    co().execute("DELETE FROM kine WHERE id = ?", (compte_id,))
    co().commit()
    flash("Praticien retiré. Il ne sera plus proposé ; les séances passées "
          "conservent son nom.")
    return redirect(url_for("admin_panel") + "#praticiens")


# -- Données de test (réservées à l'admin) --
@app.route("/test/jour", methods=["POST"])
@admin_requise
def test_jour():
    jour = (request.form.get("date") or date.today().isoformat()).strip()
    try:
        nombre = max(1, min(150, int(request.form.get("nombre") or 25)))
    except ValueError:
        nombre = 25
    db = co()
    prats = liste_praticiens()
    for _ in range(nombre):
        _ajouter_seance_demo(db, _creer_patient_demo(db), jour, prats)
    db.commit()
    flash("%d patient(s) de démo ajouté(s) le %s." % (nombre, jour))
    return redirect(url_for("admin_panel") + "#donnees")


@app.route("/test/mois", methods=["POST"])
@admin_requise
def test_mois():
    val = (request.form.get("aaaamm") or "").strip()
    try:
        annee, mois = int(val[:4]), int(val[5:7])
    except (ValueError, IndexError):
        t = date.today()
        annee, mois = t.year, t.month
    try:
        nombre = max(1, min(400, int(request.form.get("nombre") or 60)))
    except ValueError:
        nombre = 60
    njours = calendar.monthrange(annee, mois)[1]
    db = co()
    prats = liste_praticiens()
    for _ in range(nombre):
        jour = "%04d-%02d-%02d" % (annee, mois, random.randint(1, njours))
        _ajouter_seance_demo(db, _creer_patient_demo(db), jour, prats)
    db.commit()
    flash("%d séance(s) de démo réparties sur %02d/%04d." % (nombre, mois, annee))
    return redirect(url_for("admin_panel") + "#donnees")


@app.route("/test/purge", methods=["POST"])
@admin_requise
def test_purge():
    db = co()
    db.execute("DELETE FROM seances WHERE patient_id IN (SELECT id FROM patients WHERE demo = 1)")
    db.execute("DELETE FROM patients WHERE demo = 1")
    db.commit()
    flash("Données de démonstration supprimées.")
    return redirect(url_for("admin_panel") + "#donnees")


@app.context_processor
def injecter():
    return {
        "AUDIO_DISPO": AUDIO_DISPO,
        "LLM_DISPO": AUDIO_DISPO,
        "praticiens": liste_praticiens(),
        "praticiens_couleurs": praticiens_couleurs(),
        "est_admin": est_admin(),
        "annee": datetime.now().year,
        "aujourdhui": date.today().isoformat(),
    }


def ip_locale():
    """Adresse IP du PC sur le réseau local (sans rien émettre), sinon None."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except OSError:
        ip = None
    finally:
        s.close()
    return ip


def generer_certificat(cert_path, key_path, ip):
    """Crée un certificat auto-signé (localhost + IP locale) pour servir en HTTPS.

    Le micro des navigateurs n'est autorisé qu'en contexte sécurisé (HTTPS ou
    localhost) : le HTTPS débloque donc le bilan oral depuis les autres postes.
    """
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    import ipaddress as _ipaddr

    cle = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    nom = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Cabinet kine")])
    noms_alt = [x509.DNSName("localhost"),
                x509.IPAddress(_ipaddr.ip_address("127.0.0.1"))]
    if ip:
        try:
            noms_alt.append(x509.IPAddress(_ipaddr.ip_address(ip)))
        except ValueError:
            pass
    t0 = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(nom).issuer_name(nom)
        .public_key(cle.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(t0 - timedelta(days=1))
        .not_valid_after(t0 + timedelta(days=3650))
        .add_extension(x509.SubjectAlternativeName(noms_alt), critical=False)
        .sign(cle, hashes.SHA256())
    )
    with open(key_path, "wb") as f:
        f.write(cle.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.TraditionalOpenSSL,
                                  serialization.NoEncryption()))
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


if __name__ == "__main__":
    init_db()
    port = 5001
    ip = ip_locale()
    ici = os.path.dirname(os.path.abspath(__file__))
    cert_path = os.path.join(ici, "cert.pem")
    key_path = os.path.join(ici, "key.pem")
    contexte_ssl = None
    try:
        if not (os.path.exists(cert_path) and os.path.exists(key_path)):
            generer_certificat(cert_path, key_path, ip)
        contexte_ssl = (cert_path, key_path)
    except Exception as err:
        print("\n  (HTTPS indisponible : %s — démarrage en HTTP)" % err)
    schema = "https" if contexte_ssl else "http"
    print("\n  Cabinet kiné — prêt.\n")
    print("  Sur CET ordinateur :")
    print("      %s://localhost:%d" % (schema, port))
    print("      %s://127.0.0.1:%d   (si « localhost » ne répond pas)" % (schema, port))
    if ip:
        print("\n  Depuis un autre PC / smartphone sur le MÊME réseau :")
        print("      %s://%s:%d" % (schema, ip, port))
        if contexte_ssl:
            print("\n  (1re visite sur chaque appareil : le navigateur affiche un")
            print("   avertissement de sécurité — normal avec un certificat local.")
            print("   Cliquez sur « Avancé » puis « Continuer ». Le HTTPS est requis")
            print("   pour autoriser le micro — donc le bilan oral — à distance.)")
        else:
            print("\n  (connexion non chiffrée : le micro ne sera pas disponible")
            print("   depuis les autres postes)")
    print("\n  Pour arrêter : Ctrl+C\n")
    app.run(host="0.0.0.0", port=port, threaded=True, ssl_context=contexte_ssl)
__FIN_APP_PY__

info "  · resume.py"
cat > "$APP/resume.py" << '__FIN_RESUME_PY__'
#!/usr/bin/env python3
"""Résumé LOCAL du bilan oral via Ollama (avec repli par règles si Ollama est absent).

Aucune donnée ne quitte la machine : Ollama tourne en local sur le port 11434.
Utilise uniquement la bibliothèque standard (pas de dépendance pip).
"""
import json
import re
import urllib.request

OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
MODELE = "llama3.2:3b"

SYSTEME = (
    "Tu es l'assistant d'un kinésithérapeute. À partir de la dictée brute d'un "
    "bilan de séance, rédige en français un résumé clair et concis des éléments "
    "cliniquement pertinents, en quelques phrases courtes : ce qui a été fait, "
    "l'évolution, la douleur, les objectifs. N'invente rien ; garde uniquement ce "
    "qui est dit. Pas de préambule, donne directement le résumé."
)

SYSTEME_REFORM = (
    "Tu es l'assistant d'un kinésithérapeute. Reformule le texte suivant, qui décrit "
    "ce qui a été fait lors d'une séance, pour qu'il soit clair, concis et "
    "professionnel, en français. Corrige l'orthographe et la grammaire. N'ajoute "
    "aucune information et ne retire aucun fait : garde strictement le même sens. "
    "Réponds uniquement par le texte reformulé, sans préambule ni commentaire."
)


def resumer(texte):
    """Retourne {'resume': ..., 'moteur': 'ollama'|'règles'|'vide'}."""
    texte = (texte or "").strip()
    if not texte:
        return {"resume": "", "moteur": "vide"}
    try:
        return {"resume": _ollama(SYSTEME, texte), "moteur": "ollama"}
    except Exception:
        return {"resume": _regles(texte), "moteur": "règles"}


def reformuler(texte):
    """Réécrit un texte de séance (clarté/orthographe) sans changer le sens.

    Retourne {'texte': ..., 'moteur': 'ollama'|'indisponible'|'vide'}.
    En cas d'absence d'Ollama, renvoie le texte d'origine inchangé.
    """
    texte = (texte or "").strip()
    if not texte:
        return {"texte": "", "moteur": "vide"}
    try:
        return {"texte": _ollama(SYSTEME_REFORM, texte), "moteur": "ollama"}
    except Exception:
        return {"texte": texte, "moteur": "indisponible"}


def _ollama(systeme, texte):
    corps = json.dumps({
        "model": MODELE,
        "prompt": systeme + "\n\nTexte :\n" + texte + "\n\nRésultat :",
        "stream": False,
        "options": {"temperature": 0.2},
    }).encode("utf-8")
    req = urllib.request.Request(
        OLLAMA_URL, data=corps, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=240) as r:
        data = json.loads(r.read().decode("utf-8"))
    sortie = (data.get("response") or "").strip()
    if not sortie:
        raise ValueError("réponse vide d'Ollama")
    return sortie


def _regles(texte):
    """Repli sans IA : garde les phrases porteuses de sens clinique, en puces."""
    phrases = re.split(r"(?<=[.!?])\s+", texte)
    cles = (
        "douleur", "amplitude", "exercice", "renforc", "étire", "etire", "mobilis",
        "objectif", "progrès", "progres", "séance", "seance", "marche", "gainage",
        "raide", "souple", "force", "reprise", "mieux", "moins", "plus", "degré", "degre",
    )
    gardees = [p.strip() for p in phrases if any(k in p.lower() for k in cles)]
    if not gardees:
        gardees = [p.strip() for p in phrases if p.strip()]
    return "\n".join("- " + p for p in gardees if p)


def detecter_douleur(texte):
    """Repère un niveau de douleur cité (ex. « 3 sur 10 », « EVA 4 »). 0 si rien."""
    t = (texte or "").lower()
    for motif in (
        r"(\d{1,2})\s*(?:/|sur)\s*10",
        r"eva\D{0,6}(\d{1,2})",
        r"douleur\D{0,15}(\d{1,2})",
    ):
        m = re.search(motif, t)
        if m:
            v = int(m.group(1))
            if 0 <= v <= 10:
                return v
    return 0
__FIN_RESUME_PY__

info "  · pdf_export.py"
cat > "$APP/pdf_export.py" << '__FIN_PDF_EXPORT_PY__'
#!/usr/bin/env python3
"""Génère un compte-rendu PDF du dossier patient (reportlab).

Contenu : identité, pathologie, objectifs, note, courbe d'évolution de la
douleur (EVA) et historique des séances. Renvoie les octets du PDF.
"""
import io
from datetime import date, datetime

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.colors import HexColor, white
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_RIGHT
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether,
)
from reportlab.graphics.shapes import Drawing, Line, Circle, PolyLine, String

# Charte (cohérente avec l'application)
ACCENT = HexColor("#5A4FE3")
INK = HexColor("#161A23")
MUTED = HexColor("#5A6473")
LIGNE = HexColor("#DCE0E8")
SOFT = HexColor("#F0EFFC")
PATHO_BG = HexColor("#FBF1EE")
VERT = HexColor("#1F9D6B")
ORANGE = HexColor("#E0A100")
ROUGE = HexColor("#D2493B")


def _coul(n):
    if not n:
        return MUTED
    if n <= 3:
        return VERT
    if n <= 6:
        return ORANGE
    return ROUGE


def _jolie_date(iso):
    try:
        d = datetime.strptime(iso[:10], "%Y-%m-%d")
        return d.strftime("%d/%m/%Y")
    except Exception:
        return iso or ""


def _styles():
    s = getSampleStyleSheet()
    base = ParagraphStyle("base", parent=s["Normal"], fontName="Helvetica",
                          fontSize=10, leading=14, textColor=INK)
    return {
        "titre": ParagraphStyle("titre", parent=base, fontName="Helvetica-Bold",
                                fontSize=20, leading=24, textColor=INK),
        "sous": ParagraphStyle("sous", parent=base, fontSize=10, textColor=MUTED),
        "eyebrow": ParagraphStyle("eyebrow", parent=base, fontName="Helvetica-Bold",
                                  fontSize=8, textColor=MUTED, spaceAfter=2),
        "h2": ParagraphStyle("h2", parent=base, fontName="Helvetica-Bold",
                             fontSize=11, leading=14, textColor=INK, spaceBefore=4, spaceAfter=6),
        "val": ParagraphStyle("val", parent=base, fontSize=11, leading=15),
        "valbold": ParagraphStyle("valbold", parent=base, fontName="Helvetica-Bold",
                                  fontSize=12, leading=16),
        "base": base,
        "cell": ParagraphStyle("cell", parent=base, fontSize=9.5, leading=13),
        "cellmuted": ParagraphStyle("cellmuted", parent=base, fontSize=9.5,
                                    leading=13, textColor=MUTED),
        "pied": ParagraphStyle("pied", parent=base, fontSize=8, textColor=MUTED),
    }


def _graphe_douleur(points, largeur, hauteur=165):
    d = Drawing(largeur, hauteur)
    padL, padR, padT, padB = 26, 10, 12, 32
    plotW = largeur - padL - padR
    plotH = hauteur - padT - padB
    n = len(points)

    for lvl in range(0, 11, 2):
        y = padB + (lvl / 10.0) * plotH
        d.add(Line(padL, y, largeur - padR, y, strokeColor=LIGNE, strokeWidth=0.5))
        d.add(String(padL - 5, y - 3, str(lvl), fontSize=7,
                     fillColor=MUTED, textAnchor="end"))

    def X(i):
        return padL + (plotW / 2.0 if n == 1 else (i / (n - 1.0)) * plotW)

    def Y(v):
        return padB + (v / 10.0) * plotH

    if n >= 2:
        flat = []
        for i, p in enumerate(points):
            flat += [X(i), Y(p["d"])]
        d.add(PolyLine(flat, strokeColor=ACCENT, strokeWidth=1.5))

    step = 1 if n <= 12 else (n // 12 + 1)
    for i, p in enumerate(points):
        d.add(Circle(X(i), Y(p["d"]), 3, fillColor=_coul(p["d"]),
                     strokeColor=white, strokeWidth=1))
        if i % step == 0:
            d.add(String(X(i), padB - 12, p["date"][5:], fontSize=6.5,
                         fillColor=MUTED, textAnchor="middle"))
    d.add(Line(padL, padB, largeur - padR, padB, strokeColor=MUTED, strokeWidth=0.8))
    return d


def _bloc_clef(titre, valeur, st, accent=False):
    eyebrow = ParagraphStyle("eb", parent=st["eyebrow"],
                             textColor=(ROUGE if accent else MUTED))
    contenu = [
        Paragraph(titre.upper(), eyebrow),
        Paragraph(valeur or "Non renseigné",
                  st["valbold"] if accent else st["val"]),
    ]
    t = Table([[contenu]], colWidths=["100%"])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), PATHO_BG if accent else white),
        ("BOX", (0, 0), (-1, -1), 0.7, (HexColor("#F1D9D1") if accent else LIGNE)),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 9),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
        ("ROUNDEDCORNERS", [6, 6, 6, 6]),
    ]))
    return t


def generer_fiche(patient, seances):
    st = _styles()
    buf = io.BytesIO()
    marge = 18 * mm
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        leftMargin=marge, rightMargin=marge, topMargin=16 * mm, bottomMargin=16 * mm,
        title="Bilan kinésithérapie", author="Cabinet kiné",
    )
    util = A4[0] - 2 * marge
    story = []

    nom = f"{patient.get('nom','')} {patient.get('prenom','')}".strip()

    # En-tête
    gauche = [
        Paragraph("BILAN KINÉSITHÉRAPIE", st["eyebrow"]),
        Paragraph(nom or "Patient", st["titre"]),
    ]
    sous = []
    if patient.get("naissance"):
        sous.append("Né(e) le " + _jolie_date(patient["naissance"]))
    sous.append("Édité le " + date.today().strftime("%d/%m/%Y"))
    gauche.append(Paragraph(" · ".join(sous), st["sous"]))
    story.append(Table([[gauche]], colWidths=[util], style=TableStyle([
        ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0),
        ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 0), (-1, -1), 1, LIGNE),
    ])))
    story.append(Spacer(1, 14))

    # Pathologie + objectifs
    col = (util - 12) / 2.0
    story.append(_bloc_clef("Pathologie", patient.get("pathologie"), st, accent=True))
    story.append(Spacer(1, 8))
    obj = Table(
        [[_bloc_clef("Objectif court terme", patient.get("objectif_court"), st),
          _bloc_clef("Objectif long terme", patient.get("objectif_long"), st)]],
        colWidths=[col, col],
    )
    obj.setStyle(TableStyle([
        ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (0, 0), 12),
        ("RIGHTPADDING", (1, 0), (1, 0), 0),
        ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    story.append(obj)
    story.append(Spacer(1, 14))

    # Note libre
    if patient.get("note_libre"):
        story.append(Paragraph("Note", st["h2"]))
        note = Table([[Paragraph(patient["note_libre"].replace("\n", "<br/>"), st["base"])]],
                     colWidths=[util])
        note.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), HexColor("#FFFDF6")),
            ("BOX", (0, 0), (-1, -1), 0.7, HexColor("#F0E4BE")),
            ("LEFTPADDING", (0, 0), (-1, -1), 10), ("RIGHTPADDING", (0, 0), (-1, -1), 10),
            ("TOPPADDING", (0, 0), (-1, -1), 8), ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
        ]))
        story.append(note)
        story.append(Spacer(1, 14))

    seances = sorted(seances, key=lambda s: s.get("date_seance", ""))
    points = [{"date": s["date_seance"], "d": s["douleur"]}
              for s in seances if s.get("douleur")]

    # Graphe douleur
    if points:
        bloc = [Paragraph("Évolution de la douleur (EVA)", st["h2"]),
                _graphe_douleur(points, util)]
        story.append(KeepTogether(bloc))
        story.append(Spacer(1, 14))

    # Historique des séances
    story.append(Paragraph("Historique des séances", st["h2"]))
    if seances:
        entete = [Paragraph("<b>Date</b>", st["cell"]),
                  Paragraph("<b>EVA</b>", st["cell"]),
                  Paragraph("<b>Séance</b>", st["cell"])]
        lignes = [entete]
        for s in reversed(seances):  # plus récentes d'abord
            eva = str(s["douleur"]) if s.get("douleur") else "—"
            fait = (s.get("fait") or "").replace("\n", "<br/>") or "<i>—</i>"
            lignes.append([
                Paragraph(_jolie_date(s["date_seance"]), st["cellmuted"]),
                Paragraph(eva, st["cell"]),
                Paragraph(fait, st["cell"]),
            ])
        tbl = Table(lignes, colWidths=[24 * mm, 14 * mm, util - 38 * mm], repeatRows=1)
        style = [
            ("LINEBELOW", (0, 0), (-1, 0), 0.8, ACCENT),
            ("LINEBELOW", (0, 1), (-1, -1), 0.4, LIGNE),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 6), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ("LEFTPADDING", (0, 0), (-1, -1), 4), ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ]
        for i, s in enumerate(reversed(seances), start=1):
            if s.get("douleur"):
                style.append(("TEXTCOLOR", (1, i), (1, i), _coul(s["douleur"])))
                style.append(("FONTNAME", (1, i), (1, i), "Helvetica-Bold"))
        tbl.setStyle(TableStyle(style))
        story.append(tbl)
    else:
        story.append(Paragraph("Aucune séance enregistrée.", st["cellmuted"]))

    def pied(canvas, doc_):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(MUTED)
        canvas.drawString(marge, 10 * mm, "Document confidentiel — secret médical")
        canvas.drawRightString(A4[0] - marge, 10 * mm, "Page %d" % doc_.page)
        canvas.restoreState()

    doc.build(story, onFirstPage=pied, onLaterPages=pied)
    return buf.getvalue()
__FIN_PDF_EXPORT_PY__

info "  · templates/base.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/base.html" << '__FIN_TEMPLATES_BASE_HTML__'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{% block titre %}Cabinet kiné{% endblock %}</title>
<link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body class="{% block body_classe %}app{% endblock %}">
{% block chrome %}
  <aside class="rail">
    <div class="rail-mark">
      <span class="rail-dot"></span>
      Cabinet kiné
    </div>
    <nav class="rail-nav">
      <a href="{{ url_for('dashboard') }}" class="{% block nav_dash %}{% endblock %}">Patients</a>
      <a href="{{ url_for('calendrier') }}" class="{% block nav_cal %}{% endblock %}">Calendrier</a>
      <a href="{{ url_for('patient_nouveau') }}" class="{% block nav_new %}{% endblock %}">Nouveau patient</a>
      <a href="{{ url_for('archives') }}" class="{% block nav_arch %}{% endblock %}">Archives</a>
    </nav>
    <div class="rail-foot">
      {% if est_admin %}<a href="{{ url_for('admin_panel') }}" class="rail-test">Administration</a>{% endif %}
      <a href="{{ url_for('securite') }}" class="rail-test">Sécurité</a>
      <span class="local-tag">Tout en local</span>
      <a href="{{ url_for('deconnexion') }}" class="rail-out">Déconnexion</a>
    </div>
  </aside>
  <main class="stage {% block stage_classe %}{% endblock %}">
    {% with messages = get_flashed_messages() %}
      {% if messages %}
        <div class="flash">{% for m in messages %}<div>{{ m }}</div>{% endfor %}</div>
      {% endif %}
    {% endwith %}
    {% block contenu %}{% endblock %}
  </main>
{% endblock %}
{% block scripts %}{% endblock %}
</body>
</html>
__FIN_TEMPLATES_BASE_HTML__

info "  · templates/setup.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/setup.html" << '__FIN_TEMPLATES_SETUP_HTML__'
{% extends "base.html" %}
{% block titre %}Bienvenue — Cabinet kiné{% endblock %}
{% block body_classe %}center{% endblock %}
{% block chrome %}
<div class="auth-card">
  <div class="eyebrow">Première utilisation · tout reste en local</div>
  <h1>Créer votre compte</h1>
  <p class="lede">Ce compte protège l'accès aux dossiers. Choisissez vos identifiants ; ils restent sur cette machine.</p>
  {% with messages = get_flashed_messages() %}
    {% if messages %}<div class="flash">{% for m in messages %}<div>{{ m }}</div>{% endfor %}</div>{% endif %}
  {% endwith %}
  <form method="post">
    <label class="champ"><span>Identifiant</span>
      <input type="text" name="identifiant" autocomplete="username" required autofocus></label>
    <label class="champ"><span>Mot de passe (6 caractères minimum)</span>
      <input type="password" name="mdp" autocomplete="new-password" required></label>
    <label class="champ"><span>Confirmer le mot de passe</span>
      <input type="password" name="mdp2" autocomplete="new-password" required></label>
    <label class="champ"><span>Question de sécurité (pour récupérer le mot de passe)</span>
      <input type="text" name="question" maxlength="120" required
             value="Quelle est la marque de ma première voiture ?"></label>
    <label class="champ"><span>Réponse</span>
      <input type="text" name="reponse" maxlength="80" autocomplete="off" required></label>
    <button class="btn" type="submit" style="width:100%; justify-content:center;">Créer le compte</button>
  </form>
</div>
{% endblock %}
__FIN_TEMPLATES_SETUP_HTML__

info "  · templates/connexion.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/connexion.html" << '__FIN_TEMPLATES_CONNEXION_HTML__'
{% extends "base.html" %}
{% block titre %}Connexion — Cabinet kiné{% endblock %}
{% block body_classe %}center{% endblock %}
{% block chrome %}
<div class="auth-card">
  <div class="eyebrow">Cabinet kiné · accès privé</div>
  <h1>Connexion</h1>
  <p class="lede">Accédez à vos dossiers patients.</p>
  {% with messages = get_flashed_messages() %}
    {% if messages %}<div class="flash">{% for m in messages %}<div>{{ m }}</div>{% endfor %}</div>{% endif %}
  {% endwith %}
  <form method="post">
    <label class="champ"><span>Identifiant</span>
      <input type="text" name="identifiant" autocomplete="username" required autofocus></label>
    <label class="champ"><span>Mot de passe</span>
      <input type="password" name="mdp" autocomplete="current-password" required></label>
    <button class="btn" type="submit" style="width:100%; justify-content:center;">Se connecter</button>
  </form>
  <a class="lien-discret" href="{{ url_for('mdp_oublie') }}">Mot de passe oublié ?</a>
</div>
{% endblock %}
__FIN_TEMPLATES_CONNEXION_HTML__

info "  · templates/dashboard.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/dashboard.html" << '__FIN_TEMPLATES_DASHBOARD_HTML__'
{% extends "base.html" %}
{% block titre %}Patients — Cabinet kiné{% endblock %}
{% block nav_dash %}actif{% endblock %}
{% block contenu %}
<div class="row-between">
  <div>
    <h1 class="page">Patients</h1>
    <p class="page-lede">{{ patients|length }} dossier{{ 's' if patients|length != 1 else '' }} actif{{ 's' if patients|length != 1 else '' }}.</p>
  </div>
  <a class="btn" href="{{ url_for('patient_nouveau') }}">+ Nouveau patient</a>
</div>

{% if patients %}
<div class="patients">
  {% for p in patients %}
  <a class="pcard" href="{{ url_for('patient', pid=p.id) }}">
    <div class="nom">{{ p.nom }} {{ p.prenom }}{% if p.demo %} <span class="demo-tag">démo</span>{% endif %}</div>
    <div class="patho">{{ p.pathologie or "Pathologie non renseignée" }}</div>
    <div class="meta">
      <span>{{ p.nb_seances }} séance{{ 's' if p.nb_seances != 1 else '' }}</span>
      {% if p.douleur_recente %}
        <span class="pastille douleur-{{ p.douleur_recente }}">
          <span class="pip pip-{{ p.douleur_recente }}"></span>EVA {{ p.douleur_recente }}
        </span>
      {% endif %}
    </div>
  </a>
  {% endfor %}
</div>
{% else %}
<div class="vide">Aucun patient pour l'instant.<br>Cliquez sur « Nouveau patient » pour créer le premier dossier.</div>
{% endif %}

{% if nb_archives %}
<p class="page-lede" style="margin-top:28px;"><a href="{{ url_for('archives') }}">Voir les {{ nb_archives }} dossier{{ 's' if nb_archives != 1 else '' }} archivé{{ 's' if nb_archives != 1 else '' }}</a></p>
{% endif %}
{% endblock %}
__FIN_TEMPLATES_DASHBOARD_HTML__

info "  · templates/archives.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/archives.html" << '__FIN_TEMPLATES_ARCHIVES_HTML__'
{% extends "base.html" %}
{% block titre %}Archives — Cabinet kiné{% endblock %}
{% block nav_arch %}actif{% endblock %}
{% block contenu %}
<h1 class="page">Archives</h1>
<p class="page-lede">Dossiers archivés. L'historique est conservé ; vous pouvez les réactiver à tout moment.</p>

{% if patients %}
<div class="patients">
  {% for p in patients %}
  <div class="pcard" style="cursor:default;">
    <div class="nom">{{ p.nom }} {{ p.prenom }}</div>
    <div class="patho">{{ p.pathologie or "—" }}</div>
    <div class="meta" style="justify-content:space-between;">
      <a href="{{ url_for('patient', pid=p.id) }}">Ouvrir</a>
      <form method="post" action="{{ url_for('patient_restaurer', pid=p.id) }}">
        <button class="btn ghost sm" type="submit">Réactiver</button>
      </form>
    </div>
  </div>
  {% endfor %}
</div>
{% else %}
<div class="vide">Aucun dossier archivé.</div>
{% endif %}
{% endblock %}
__FIN_TEMPLATES_ARCHIVES_HTML__

info "  · templates/calendrier.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/calendrier.html" << '__FIN_TEMPLATES_CALENDRIER_HTML__'
{% extends "base.html" %}
{% block titre %}Calendrier — Cabinet kiné{% endblock %}
{% block nav_cal %}actif{% endblock %}
{% block stage_classe %}stage-large{% endblock %}
{% block contenu %}
<h1 class="page">Calendrier</h1>
<p class="page-lede">Toutes les séances du cabinet. Cliquez sur un jour pour voir les patients concernés.</p>

<div class="card">
  <div class="cal-tete">
    <div class="vue-toggle">
      <button id="vueJour" type="button">Jour</button>
      <button id="vueSemaine" type="button">Semaine</button>
      <button id="vueMois" type="button" class="actif">Mois</button>
    </div>
    <div class="mois" id="calMois"></div>
    <div class="cal-nav">
      <button id="calPrev" type="button" aria-label="Précédent">‹</button>
      <button id="calNext" type="button" aria-label="Suivant">›</button>
    </div>
  </div>
  <div class="cal-grille agenda-grille" id="calGrille"></div>
  <div class="cal-legende" id="calLegende"></div>
</div>

<!-- Fenêtre du jour -->
<div class="overlay" id="jourOverlay">
  <div class="modale" role="dialog" aria-modal="true" aria-labelledby="jourTitre">
    <h3 id="jourTitre">Séances du jour</h3>
    <div class="when" id="jourSous"></div>
    <div id="jourListe" class="jour-liste"></div>
    <div class="modale-actions" style="justify-content:flex-end;">
      <button class="btn ghost" id="jourFermer" type="button">Fermer</button>
    </div>
  </div>
</div>

<!-- Fenêtre d'ajout de créneau -->
<div class="overlay" id="creneauOverlay">
  <div class="modale" role="dialog" aria-modal="true" aria-labelledby="creneauTitre">
    <h3 id="creneauTitre">Nouveau créneau</h3>
    <div class="when" id="creneauQuand"></div>
    <label class="champ"><span>Patient</span>
      <select id="creneauPatient"></select></label>
    <label class="champ"><span>Praticien</span>
      <select id="creneauPraticien"></select></label>
    <div class="modale-actions" style="justify-content:flex-end;">
      <button class="btn ghost" id="creneauAnnuler" type="button">Annuler</button>
      <button class="btn" id="creneauOk" type="button">Ajouter au créneau</button>
    </div>
  </div>
</div>

<script>
  window.AGENDA_URL = "{{ url_for('agenda_json') }}";
  window.PATIENTS_URL = "{{ url_for('patients_json') }}";
  window.PATIENT_BASE = "{{ url_for('patient', pid=0) }}";
  window.CRENEAU_BASE = "{{ url_for('creneau_enregistrer', pid=0) }}";
  window.PRATICIENS = {{ praticiens|tojson }};
  window.PRAT_COULEURS = {{ praticiens_couleurs|tojson }};
</script>
{% endblock %}
{% block scripts %}
<script src="{{ url_for('static', filename='agenda.js') }}"></script>
{% endblock %}
__FIN_TEMPLATES_CALENDRIER_HTML__

info "  · templates/patient_form.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/patient_form.html" << '__FIN_TEMPLATES_PATIENT_FORM_HTML__'
{% extends "base.html" %}
{% block titre %}{{ "Nouveau patient" if mode == "nouveau" else "Modifier" }} — Cabinet kiné{% endblock %}
{% block nav_new %}{{ 'actif' if mode == 'nouveau' else '' }}{% endblock %}
{% block contenu %}
<h1 class="page">{{ "Nouveau patient" if mode == "nouveau" else "Modifier le dossier" }}</h1>
<p class="page-lede">La pathologie et les objectifs apparaîtront en évidence sur la fiche.</p>

<form method="post" class="card" style="max-width:720px;">
  <div class="grille2">
    <label class="champ"><span>Nom *</span>
      <input type="text" name="nom" value="{{ patient.nom or '' }}" required autofocus></label>
    <label class="champ"><span>Prénom *</span>
      <input type="text" name="prenom" value="{{ patient.prenom or '' }}" required></label>
  </div>
  <label class="champ"><span>Date de naissance</span>
    <input type="date" name="naissance" value="{{ patient.naissance or '' }}"></label>
  <label class="champ"><span>Pathologie</span>
    <input type="text" name="pathologie" value="{{ patient.pathologie or '' }}" placeholder="ex. Tendinopathie de la coiffe des rotateurs"></label>
  <div class="grille2">
    <label class="champ"><span>Objectif court terme</span>
      <textarea name="objectif_court" placeholder="ex. Retrouver l'amplitude sans douleur sous 3 semaines">{{ patient.objectif_court or '' }}</textarea></label>
    <label class="champ"><span>Objectif long terme</span>
      <textarea name="objectif_long" placeholder="ex. Reprise du sport sans appréhension">{{ patient.objectif_long or '' }}</textarea></label>
  </div>
  <label class="champ"><span>Note libre (particularités du patient)</span>
    <textarea name="note_libre" placeholder="ex. dépendant·e, déteste les courbatures, à rassurer…">{{ patient.note_libre or '' }}</textarea></label>

  <div style="display:flex; gap:10px; margin-top:8px;">
    <button class="btn" type="submit">{{ "Créer le dossier" if mode == "nouveau" else "Enregistrer" }}</button>
    <a class="btn ghost" href="{{ url_for('patient', pid=patient.id) if patient.id else url_for('dashboard') }}">Annuler</a>
  </div>
</form>
{% endblock %}
__FIN_TEMPLATES_PATIENT_FORM_HTML__

info "  · templates/patient.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/patient.html" << '__FIN_TEMPLATES_PATIENT_HTML__'
{% extends "base.html" %}
{% block titre %}{{ p.nom }} {{ p.prenom }} — Cabinet kiné{% endblock %}
{% block contenu %}
<div class="fiche-tete">
  <div class="row-between">
    <div>
      <a href="{{ url_for('dashboard') }}" style="font-size:13px;">← Patients</a>
      <h1>{{ p.nom }} {{ p.prenom }}</h1>
      <div class="sous">
        {% if p.naissance %}Né(e) le {{ p.naissance }} · {% endif %}
        Dossier créé le {{ p.cree_le[:10] }}
        {% if p.archive %} · <strong style="color:var(--danger)">archivé</strong>{% endif %}
      </div>
    </div>
    <div style="display:flex; gap:8px;">
      <a class="btn ghost sm" href="{{ url_for('patient_pdf', pid=p.id) }}">Exporter en PDF</a>
      <a class="btn ghost sm" href="{{ url_for('patient_modifier', pid=p.id) }}">Modifier</a>
      {% if p.archive %}
        <form method="post" action="{{ url_for('patient_restaurer', pid=p.id) }}"><button class="btn ghost sm">Réactiver</button></form>
      {% else %}
        <form method="post" action="{{ url_for('patient_archiver', pid=p.id) }}" onsubmit="return confirm('Archiver ce dossier ? L\'historique est conservé.')"><button class="btn danger sm">Archiver</button></form>
      {% endif %}
    </div>
  </div>
</div>

<!-- Infos clés en évidence -->
<div class="bandeau">
  <div class="bloc-clef patho">
    <div class="k">Pathologie</div>
    <div class="v {{ '' if p.pathologie else 'vide-v' }}">{{ p.pathologie or "Non renseignée" }}</div>
  </div>
  <div class="bloc-clef">
    <div class="k">Objectif court terme</div>
    <div class="v {{ '' if p.objectif_court else 'vide-v' }}" style="font-size:14px; font-weight:500;">{{ p.objectif_court or "Non renseigné" }}</div>
  </div>
  <div class="bloc-clef">
    <div class="k">Objectif long terme</div>
    <div class="v {{ '' if p.objectif_long else 'vide-v' }}" style="font-size:14px; font-weight:500;">{{ p.objectif_long or "Non renseigné" }}</div>
  </div>
</div>

<!-- Note libre -->
<div class="card note-zone">
  <h2>Note du patient</h2>
  <form method="post" action="{{ url_for('patient_note', pid=p.id) }}">
    <textarea name="note_libre" placeholder="Particularités à garder en tête…">{{ p.note_libre or '' }}</textarea>
    <div class="note-row"><button class="btn ghost sm" type="submit">Enregistrer la note</button></div>
  </form>
</div>

<!-- Bilan oral -->
{% if AUDIO_DISPO %}
<div class="card" id="bilan">
  <h2>Bilan oral</h2>
  <p class="aide">Dictez votre bilan : transcription et résumé sont calculés en local, rien n'est envoyé en ligne. Relisez le résumé avant de l'insérer.</p>
  <div class="rec-row">
    <button id="recBtn" class="rec-btn" type="button" aria-label="Démarrer la dictée"><span class="dot"></span></button>
    <div id="meter" class="meter" aria-hidden="true">
      <span class="bar"></span><span class="bar"></span><span class="bar"></span><span class="bar"></span>
      <span class="bar"></span><span class="bar"></span><span class="bar"></span><span class="bar"></span>
      <span class="bar"></span><span class="bar"></span><span class="bar"></span><span class="bar"></span>
    </div>
    <div id="timer" class="timer">0:00</div>
  </div>
  <p class="hint" id="recHint">Cliquez pour dicter. Re-cliquez pour arrêter et lancer la transcription.</p>
  <div class="status" id="bilanStatus" role="status" aria-live="polite"></div>

  <div class="bilan-res" id="bilanRes" style="display:none;">
    <label class="champ"><span>Résumé du bilan (modifiable)</span>
      <textarea id="bilanResume" style="min-height:120px;"></textarea></label>
    <details><summary>Voir la transcription brute</summary>
      <div class="brut" id="bilanBrut"></div></details>
    <label class="champ" style="max-width:240px; margin-top:14px;"><span>Date de la séance</span>
      <input type="date" id="bilanDate"></label>
    <div class="hint" id="dateInfo" style="margin-top:0;"></div>
    <div class="bilan-actions">
      <span class="moteur-tag" id="moteurTag"></span>
      <div style="display:flex; gap:8px;">
        <button class="btn ghost" id="bilanNote" type="button">Ajouter à la note</button>
        <button class="btn" id="bilanSeance" type="button">Insérer dans la séance</button>
      </div>
    </div>
  </div>
</div>
{% else %}
<div class="card" id="bilan">
  <h2>Bilan oral</h2>
  <p class="aide">Le module audio n'est pas installé. Pour l'activer : <code>bash installer.sh --avec-audio</code>, puis relancez l'application.</p>
</div>
{% endif %}

<!-- Calendrier -->
<div class="card">
  <h2>Calendrier des séances</h2>
  <div class="cal-tete">
    <div class="cal-nav"><button id="calPrev" type="button" aria-label="Mois précédent">‹</button></div>
    <div class="mois" id="calMois"></div>
    <div class="cal-nav"><button id="calNext" type="button" aria-label="Mois suivant">›</button></div>
  </div>
  <div class="cal-grille" id="calGrille"></div>
  <div class="cal-legende">
    <span><span class="lg" style="background:var(--accent)"></span> séance notée</span>
    <span><span class="lg" style="background:var(--ok)"></span> douleur faible (1-3)</span>
    <span><span class="lg" style="background:var(--warn)"></span> modérée (4-6)</span>
    <span><span class="lg" style="background:var(--danger)"></span> forte (7-10)</span>
  </div>
</div>

<!-- Graphique douleur -->
<div class="card">
  <h2>Évolution de la douleur (EVA)</h2>
  <div class="graph-wrap" id="graphWrap">
    <div class="graph-vide" id="graphVide">Pas encore de douleur enregistrée. Notez une séance pour voir la courbe.</div>
  </div>
</div>

<!-- Séances -->
<div class="card" id="seances">
  <h2>Séances <span class="compteur">· {{ seances|length }}</span></h2>
  {% if seances %}
    {% for s in seances %}
    <div class="seance-item">
      <div class="tete">
        <span class="date">{{ s.date_seance }}</span>
        <div style="display:flex; align-items:center; gap:10px;">
          {% if s.douleur %}<span class="pastille douleur-{{ s.douleur }}"><span class="pip pip-{{ s.douleur }}"></span>EVA {{ s.douleur }}</span>{% endif %}
          <button class="btn ghost sm js-edit"
                  data-date="{{ s.date_seance }}"
                  data-fait="{{ s.fait or '' }}"
                  data-douleur="{{ s.douleur or 0 }}">Modifier</button>
        </div>
      </div>
      {% if s.fait %}<div class="fait">{{ s.fait }}</div>{% endif %}
    </div>
    {% endfor %}
  {% else %}
    <div class="vide" style="padding:30px;">Aucune séance enregistrée.<br>Cliquez sur un jour du calendrier pour en ajouter une.</div>
  {% endif %}
</div>

<!-- Modale séance -->
<div class="overlay" id="overlay">
  <div class="modale" role="dialog" aria-modal="true" aria-labelledby="modTitre">
    <h3 id="modTitre">Séance</h3>
    <div class="when" id="modDate"></div>
    <form method="post" action="{{ url_for('seance_enregistrer', pid=p.id) }}" id="seanceForm">
      <input type="hidden" name="date_seance" id="fDate">
      <div class="grille2">
        <label class="champ"><span>Heure du créneau</span>
          <select name="heure" id="fHeure">
            <option value="">— sans horaire —</option>
            {% for h in range(7, 20) %}
            <option value="{{ '%02d:00'|format(h) }}">{{ '%02d:00'|format(h) }}</option>
            <option value="{{ '%02d:30'|format(h) }}">{{ '%02d:30'|format(h) }}</option>
            {% endfor %}
          </select></label>
        <label class="champ"><span>Praticien</span>
          <select name="praticien" id="fPraticien">
            <option value="">—</option>
            {% for pr in praticiens %}<option value="{{ pr }}">{{ pr }}</option>{% endfor %}
          </select></label>
      </div>
      <label class="champ"><span>Ce qui a été fait</span>
        <textarea name="fait" id="fFait" placeholder="Exercices, manipulations, ressenti…"></textarea></label>
      <div class="reform-row">
        <button type="button" class="btn ghost sm" id="reformBtn">Reformuler</button>
        <button type="button" class="btn ghost sm" id="reformUndo" style="display:none;">Rétablir</button>
        <span class="reform-status" id="reformStatus"></span>
      </div>
      <div class="eva">
        <div class="eva-haut">
          <span style="font-size:13px;color:var(--muted);">Niveau de douleur</span>
          <span class="eva-val" id="evaVal">—</span>
        </div>
        <input type="range" name="douleur" id="fDouleur" min="0" max="10" value="0" step="1">
        <div class="eva-echelle"><span>aucune</span><span>5</span><span>10 max</span></div>
      </div>
      <div class="modale-actions">
        <button type="button" class="btn ghost sm" id="modSupprimer" style="visibility:hidden;">Supprimer</button>
        <div style="display:flex; gap:8px;">
          <button type="button" class="btn ghost" id="modFermer">Annuler</button>
          <button type="submit" class="btn">Enregistrer</button>
        </div>
      </div>
    </form>
    <form method="post" id="supprimerForm" style="display:none;"></form>
  </div>
</div>

<script>
  window.PATIENT_ID = {{ p.id }};
  window.SEANCES_URL = "{{ url_for('seances_json', pid=p.id) }}";
  window.SUPPR_BASE = "{{ url_for('seance_supprimer', pid=p.id, sid=0) }}";
  window.SEANCE_URL = "{{ url_for('seance_enregistrer', pid=p.id) }}";
  window.NOTE_URL = "{{ url_for('patient_note', pid=p.id) }}";
  window.BILAN_URL = "{{ url_for('bilan_oral', pid=p.id) }}" ;
  window.REFORM_URL = "{{ url_for('reformuler') }}";
  window.AUDIO_DISPO = {{ 'true' if AUDIO_DISPO else 'false' }};
  window.AUJOURDHUI = "{{ aujourdhui }}";
</script>
{% endblock %}
{% block scripts %}
<script src="{{ url_for('static', filename='app.js') }}"></script>
{% endblock %}
__FIN_TEMPLATES_PATIENT_HTML__

info "  · templates/admin_panel.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/admin_panel.html" << '__FIN_TEMPLATES_ADMIN_PANEL_HTML__'
{% extends "base.html" %}
{% block titre %}Administration — Cabinet kiné{% endblock %}
{% block contenu %}
<h1 class="page">Administration</h1>
<p class="page-lede">Réservé au compte administrateur : gestion des praticiens et données de test.</p>

{% with messages = get_flashed_messages() %}
  {% if messages %}<div class="flash">{% for m in messages %}<div>{{ m }}</div>{% endfor %}</div>{% endif %}
{% endwith %}

<div class="card" id="praticiens">
  <h2>Praticiens</h2>
  <p class="aide">Chaque praticien a son propre compte : il se connecte avec son nom et son mot de passe, et il est proposé lors de la planification des séances. Seul l'administrateur peut gérer cette liste et générer des données de test.</p>
  <ul class="prat-liste">
    {% for c in comptes %}
    <li>
      {% if c.role == 'admin' %}
        <span class="role-tag role-admin">admin</span>
        <span class="prat-nom">{{ c.identifiant }}{% if c.id == moi %} <span class="aide">(vous)</span>{% endif %}</span>
      {% else %}
        <span class="prat-pastille" style="background:{{ couleurs[c.identifiant] }}"></span>
        <span class="prat-nom">{{ c.identifiant }}</span>
        <form method="post" action="{{ url_for('admin_compte_supprimer', compte_id=c.id) }}"
              onsubmit="return confirm('Retirer le praticien {{ c.identifiant }} ? Son compte sera supprimé (les séances passées gardent son nom).')">
          <button class="btn ghost sm" type="submit">Retirer</button>
        </form>
      {% endif %}
    </li>
    {% endfor %}
  </ul>
  <h3 style="margin:16px 0 6px; font-size:14px;">Ajouter un praticien</h3>
  <form method="post" action="{{ url_for('admin_compte_ajouter') }}" class="grille2">
    <label class="champ"><span>Nom (sert d'identifiant de connexion)</span>
      <input type="text" name="identifiant" minlength="3" maxlength="40" required></label>
    <label class="champ"><span>Mot de passe (6 caractères min)</span>
      <input type="password" name="mdp" minlength="6" autocomplete="new-password" required></label>
    <div style="grid-column:1/-1;"><button class="btn" type="submit">Créer le compte praticien</button></div>
  </form>
  <p class="aide">Le praticien pourra ensuite définir sa propre question de sécurité et changer son mot de passe via « Sécurité ».</p>
</div>

<div class="card" id="donnees">
  <h2>Données de test</h2>
  <p class="aide">Génère des patients fictifs (marqués « démo ») pour tester l'affichage. Réservé à l'administrateur ; tout est supprimable ci-dessous.</p>

  <h3 style="margin:14px 0 6px; font-size:14px;">Beaucoup de patients un même jour</h3>
  <form method="post" action="{{ url_for('test_jour') }}">
    <div class="grille2">
      <label class="champ"><span>Date</span>
        <input type="date" name="date" value="{{ aujourdhui }}"></label>
      <label class="champ"><span>Nombre de patients (max 150)</span>
        <input type="number" name="nombre" value="25" min="1" max="150"></label>
    </div>
    <button class="btn" type="submit">Générer ce jour-là</button>
  </form>

  <h3 style="margin:18px 0 6px; font-size:14px;">Remplir un mois</h3>
  <form method="post" action="{{ url_for('test_mois') }}">
    <div class="grille2">
      <label class="champ"><span>Mois</span>
        <input type="month" name="aaaamm" value="{{ aujourdhui[:7] }}"></label>
      <label class="champ"><span>Nombre de séances (max 400)</span>
        <input type="number" name="nombre" value="60" min="1" max="400"></label>
    </div>
    <button class="btn" type="submit">Remplir le mois</button>
  </form>

  <h3 style="margin:18px 0 6px; font-size:14px;">Nettoyage</h3>
  <p class="aide">Patients de démo actuellement en base : <strong>{{ nb_demo }}</strong>.</p>
  <form method="post" action="{{ url_for('test_purge') }}"
        onsubmit="return confirm('Supprimer tous les patients de démo et leurs séances ?')">
    <button class="btn danger" type="submit">Supprimer toutes les données de démo</button>
  </form>
</div>
{% endblock %}
__FIN_TEMPLATES_ADMIN_PANEL_HTML__

info "  · templates/mdp_oublie.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/mdp_oublie.html" << '__FIN_TEMPLATES_MDP_OUBLIE_HTML__'
{% extends "base.html" %}
{% block titre %}Mot de passe oublié — Cabinet kiné{% endblock %}
{% block body_classe %}center{% endblock %}
{% block chrome %}
<div class="auth-card">
  <div class="eyebrow">Cabinet kiné · récupération</div>
  <h1>Mot de passe oublié</h1>
  {% with messages = get_flashed_messages() %}
    {% if messages %}<div class="flash">{% for m in messages %}<div>{{ m }}</div>{% endfor %}</div>{% endif %}
  {% endwith %}
  {% if etape == 2 %}
    <p class="lede">Répondez à votre question de sécurité pour définir un nouveau mot de passe.</p>
    <form method="post">
      <input type="hidden" name="identifiant" value="{{ identifiant }}">
      <label class="champ"><span>{{ question }}</span>
        <input type="text" name="reponse" autocomplete="off" required autofocus></label>
      <label class="champ"><span>Nouveau mot de passe</span>
        <input type="password" name="mdp" autocomplete="new-password" required></label>
      <label class="champ"><span>Confirmer le mot de passe</span>
        <input type="password" name="mdp2" autocomplete="new-password" required></label>
      <button class="btn" type="submit" style="width:100%; justify-content:center;">Réinitialiser</button>
    </form>
  {% else %}
    <p class="lede">Saisissez votre identifiant pour afficher votre question de sécurité.</p>
    <form method="post">
      <label class="champ"><span>Identifiant</span>
        <input type="text" name="identifiant" autocomplete="username" required autofocus></label>
      <button class="btn" type="submit" style="width:100%; justify-content:center;">Continuer</button>
    </form>
  {% endif %}
  <a class="lien-discret" href="{{ url_for('connexion') }}">Retour à la connexion</a>
</div>
{% endblock %}
__FIN_TEMPLATES_MDP_OUBLIE_HTML__

info "  · templates/securite.html"
mkdir -p "$APP/templates"
cat > "$APP/templates/securite.html" << '__FIN_TEMPLATES_SECURITE_HTML__'
{% extends "base.html" %}
{% block titre %}Sécurité — Cabinet kiné{% endblock %}
{% block contenu %}
<h1 class="page">Sécurité du compte</h1>
<p class="page-lede">Compte : <strong>{{ compte.identifiant }}</strong></p>

{% with messages = get_flashed_messages() %}
  {% if messages %}<div class="flash">{% for m in messages %}<div>{{ m }}</div>{% endfor %}</div>{% endif %}
{% endwith %}

<div class="card">
  <h2>Changer le mot de passe</h2>
  <form method="post">
    <input type="hidden" name="action" value="mdp">
    <label class="champ"><span>Mot de passe actuel</span>
      <input type="password" name="ancien" autocomplete="current-password" required></label>
    <div class="grille2">
      <label class="champ"><span>Nouveau mot de passe</span>
        <input type="password" name="mdp" autocomplete="new-password" required></label>
      <label class="champ"><span>Confirmer</span>
        <input type="password" name="mdp2" autocomplete="new-password" required></label>
    </div>
    <button class="btn" type="submit">Modifier le mot de passe</button>
  </form>
</div>

<div class="card">
  <h2>Question de sécurité</h2>
  <p class="aide">Elle permet de réinitialiser votre mot de passe en cas d'oubli.
    {% if compte.question %}Question actuelle : « {{ compte.question }} ».{% else %}<strong>Aucune question n'est encore définie.</strong>{% endif %}</p>
  <form method="post">
    <input type="hidden" name="action" value="question">
    <label class="champ"><span>Question</span>
      <input type="text" name="question" maxlength="120" required
             value="{{ compte.question or 'Quelle est la marque de ma première voiture ?' }}"></label>
    <label class="champ"><span>Réponse</span>
      <input type="text" name="reponse" maxlength="80" autocomplete="off" required></label>
    <button class="btn" type="submit">Enregistrer la question</button>
  </form>
</div>
{% endblock %}
__FIN_TEMPLATES_SECURITE_HTML__

info "  · static/style.css"
mkdir -p "$APP/static"
cat > "$APP/static/style.css" << '__FIN_STATIC_STYLE_CSS__'
:root {
  --bg: #EAEDF2;
  --surface: #FFFFFF;
  --ink: #161A23;
  --muted: #5A6473;
  --line: #DCE0E8;
  --accent: #5A4FE3;
  --accent-deep: #463CC4;
  --accent-soft: #F0EFFC;
  --live: #E2683A;
  --ok: #1F9D6B;
  --warn: #E0A100;
  --danger: #D2493B;
  --cal-h: clamp(340px, calc(100vh - 300px), 1000px);
  --mono: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
  --sans: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  min-height: 100vh;
  background: radial-gradient(120% 80% at 50% -10%, #F4F5F9 0%, var(--bg) 55%);
  color: var(--ink);
  font-family: var(--sans);
  line-height: 1.5;
}

a { color: var(--accent); text-decoration: none; }
a:hover { color: var(--accent-deep); }

/* ---------- Pages plein écran (connexion / setup) ---------- */
body.center {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 40px 20px;
}
.auth-card {
  width: 100%;
  max-width: 400px;
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 16px;
  padding: 32px;
  box-shadow: 0 1px 0 rgba(22,26,35,0.02), 0 12px 30px -18px rgba(22,26,35,0.22);
}
.eyebrow {
  font-family: var(--mono);
  font-size: 12px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--muted);
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 14px;
}
.eyebrow::before {
  content: "";
  width: 7px; height: 7px; border-radius: 50%;
  background: var(--ok);
  box-shadow: 0 0 0 3px rgba(31,157,107,0.18);
}
.auth-card h1 { font-size: 24px; font-weight: 660; letter-spacing: -0.02em; margin: 0 0 6px; }
.auth-card .lede { color: var(--muted); margin: 0 0 24px; font-size: 14px; }

/* ---------- Application (rail + scène) ---------- */
body.app { display: flex; }

.rail {
  width: clamp(190px, 16vw, 232px);
  flex: none;
  min-height: 100vh;
  background: var(--surface);
  border-right: 1px solid var(--line);
  padding: 26px 18px;
  display: flex;
  flex-direction: column;
  position: sticky;
  top: 0;
  height: 100vh;
}
.rail-mark {
  font-weight: 680;
  letter-spacing: -0.01em;
  display: flex; align-items: center; gap: 9px;
  margin-bottom: 28px;
}
.rail-dot {
  width: 10px; height: 10px; border-radius: 3px;
  background: var(--accent);
}
.rail-nav { display: flex; flex-direction: column; gap: 2px; }
.rail-nav a {
  color: var(--ink);
  padding: 9px 12px;
  border-radius: 9px;
  font-size: 14px;
  transition: background .12s ease, color .12s ease;
}
.rail-nav a:hover { background: var(--accent-soft); color: var(--accent-deep); }
.rail-nav a.actif { background: var(--accent); color: #fff; }
.rail-foot { margin-top: auto; display: flex; flex-direction: column; gap: 12px; }
.local-tag {
  font-family: var(--mono);
  font-size: 11px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--muted);
  display: flex; align-items: center; gap: 7px;
}
.local-tag::before {
  content: ""; width: 6px; height: 6px; border-radius: 50%;
  background: var(--ok); box-shadow: 0 0 0 3px rgba(31,157,107,0.16);
}
.rail-out { font-size: 13px; color: var(--muted); }
.rail-out:hover { color: var(--danger); }
.rail-test { font-size: 13px; color: var(--muted); }
.rail-test:hover { color: var(--accent); }
.demo-tag {
  font-family: var(--mono); font-size: 10px; color: var(--muted);
  border: 1px solid var(--line); border-radius: 6px; padding: 1px 5px;
  vertical-align: 1px; font-weight: 400;
}

.stage { flex: 1; min-width: 0; padding: clamp(24px, 3vw, 40px) clamp(18px, 3.4vw, 44px) 64px; max-width: 1120px; margin: 0 auto; }
.stage-large { max-width: 1560px; }

/* ---------- Éléments communs ---------- */
.flash {
  background: #FFF7E8;
  border: 1px solid #F0DDA8;
  color: #8A6400;
  border-radius: 10px;
  padding: 12px 14px;
  font-size: 14px;
  margin-bottom: 22px;
}
.flash div + div { margin-top: 4px; }

h1.page { font-size: 28px; font-weight: 660; letter-spacing: -0.02em; margin: 0 0 4px; }
.page-lede { color: var(--muted); margin: 0 0 28px; font-size: 15px; }

.row-between { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap; }

.btn {
  font: inherit; font-size: 14px; font-weight: 560;
  padding: 10px 16px; border-radius: 10px;
  border: none; background: var(--accent); color: #fff;
  cursor: pointer; transition: background .14s ease, transform .06s ease;
  display: inline-flex; align-items: center; gap: 8px;
}
.btn:hover { background: var(--accent-deep); }
.btn:active { transform: translateY(1px); }
.btn.ghost { background: #fff; color: var(--ink); border: 1px solid var(--line); }
.btn.ghost:hover { border-color: var(--accent); color: var(--accent); }
.btn.danger { background: #fff; color: var(--danger); border: 1px solid #E6C7C2; }
.btn.danger:hover { background: var(--danger); color: #fff; border-color: var(--danger); }
.btn.sm { padding: 7px 12px; font-size: 13px; }
.btn:focus-visible, a:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; border-radius: 8px; }

.card {
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 16px;
  padding: 24px;
  box-shadow: 0 1px 0 rgba(22,26,35,0.02), 0 12px 30px -20px rgba(22,26,35,0.18);
}
.card + .card { margin-top: 20px; }
.card h2 { font-size: 15px; font-weight: 620; margin: 0 0 16px; letter-spacing: -0.01em; }
.card h2 .compteur { color: var(--muted); font-weight: 400; }

/* Champs de formulaire */
label.champ { display: block; margin-bottom: 16px; }
label.champ > span {
  display: block; font-size: 13px; color: var(--muted);
  margin-bottom: 6px; font-weight: 540;
}
input[type=text], input[type=password], input[type=date], textarea, select {
  width: 100%; font: inherit; font-size: 15px;
  padding: 10px 12px; border-radius: 10px;
  border: 1px solid var(--line); background: #FBFBFD; color: var(--ink);
}
textarea { resize: vertical; min-height: 80px; line-height: 1.55; }
input:focus-visible, textarea:focus-visible, select:focus-visible {
  outline: 3px solid var(--accent); outline-offset: 1px;
}
.grille2 { display: grid; grid-template-columns: 1fr 1fr; gap: 0 18px; }

/* ---------- Liste patients (dashboard) ---------- */
.patients { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 16px; }
.pcard {
  background: var(--surface); border: 1px solid var(--line); border-radius: 14px;
  padding: 18px; transition: border-color .14s ease, transform .08s ease, box-shadow .14s ease;
  display: block;
}
.pcard:hover { border-color: var(--accent); transform: translateY(-2px); box-shadow: 0 14px 26px -18px rgba(90,79,227,0.4); }
.pcard .nom { font-weight: 620; color: var(--ink); font-size: 16px; letter-spacing: -0.01em; }
.pcard .patho { color: var(--muted); font-size: 13px; margin-top: 4px; min-height: 18px; }
.pcard .meta { display: flex; align-items: center; gap: 10px; margin-top: 14px; font-size: 12.5px; color: var(--muted); }

.pastille {
  display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; flex: none;
  font-family: var(--mono); font-size: 12px; padding: 3px 9px; border-radius: 999px;
  border: 1px solid var(--line);
}
.pastille .pip { width: 8px; height: 8px; border-radius: 50%; }
.douleur-1, .douleur-2, .douleur-3 { color: var(--ok); }
.douleur-4, .douleur-5, .douleur-6 { color: var(--warn); }
.douleur-7, .douleur-8, .douleur-9, .douleur-10 { color: var(--danger); }
.pip-1,.pip-2,.pip-3 { background: var(--ok); }
.pip-4,.pip-5,.pip-6 { background: var(--warn); }
.pip-7,.pip-8,.pip-9,.pip-10 { background: var(--danger); }

.vide {
  text-align: center; color: var(--muted); padding: 50px 20px;
  border: 1.5px dashed var(--line); border-radius: 14px; font-size: 15px;
}

/* ---------- Fiche patient ---------- */
.fiche-tete { margin-bottom: 24px; }
.fiche-tete h1 { font-size: 30px; font-weight: 680; letter-spacing: -0.025em; margin: 6px 0 0; }
.fiche-tete .sous { color: var(--muted); font-size: 14px; margin-top: 4px; }

.bandeau { display: grid; grid-template-columns: 1.1fr 1fr 1fr; gap: 16px; margin-bottom: 20px; }
.bloc-clef {
  border-radius: 14px; padding: 18px; border: 1px solid var(--line); background: var(--surface);
}
.bloc-clef.patho { background: linear-gradient(180deg, #FBF1EE 0%, #fff 70%); border-color: #F1D9D1; }
.bloc-clef .k {
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.12em; text-transform: uppercase;
  color: var(--muted); margin-bottom: 8px;
}
.bloc-clef.patho .k { color: var(--live); }
.bloc-clef .v { font-size: 16px; font-weight: 560; letter-spacing: -0.01em; }
.bloc-clef .v.vide-v { color: var(--muted); font-weight: 400; font-style: italic; }

.note-zone textarea { background: #FFFDF6; border-color: #F0E4BE; }
.note-row { display: flex; justify-content: flex-end; margin-top: 10px; }

/* Calendrier */
.cal-tete { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
.cal-tete .mois { font-weight: 620; font-size: 15px; min-width: 150px; text-align: center; text-transform: capitalize; }
.cal-nav { display: flex; gap: 6px; }
.cal-nav button {
  width: 34px; height: 34px; border-radius: 9px; border: 1px solid var(--line);
  background: #fff; cursor: pointer; font-size: 16px; color: var(--ink);
}
.cal-nav button:hover { border-color: var(--accent); color: var(--accent); }
.cal-grille { display: grid; grid-template-columns: repeat(7, 1fr); gap: 6px; }
.cal-jour-nom { font-size: 11px; color: var(--muted); text-align: center; font-family: var(--mono); text-transform: uppercase; letter-spacing: 0.06em; padding-bottom: 4px; }
.cal-case {
  aspect-ratio: 1 / 1; border: 1px solid var(--line); border-radius: 10px;
  background: #fff; cursor: pointer; padding: 6px; position: relative;
  font-size: 13px; color: var(--ink); text-align: left;
  transition: border-color .12s ease, background .12s ease;
}
.cal-case:hover { border-color: var(--accent); background: var(--accent-soft); }
.cal-case.vide-case { background: transparent; border-color: transparent; cursor: default; }
.cal-case.ajd { box-shadow: inset 0 0 0 2px var(--accent); }
.cal-case .pt {
  position: absolute; bottom: 6px; right: 6px;
  width: 18px; height: 18px; border-radius: 50%;
  font-size: 10px; color: #fff; display: grid; place-items: center; font-weight: 600;
}
.cal-case .fait-dot { position: absolute; bottom: 8px; left: 6px; width: 7px; height: 7px; border-radius: 50%; background: var(--accent); }
.cal-legende { display: flex; gap: 16px; margin-top: 14px; font-size: 12px; color: var(--muted); flex-wrap: wrap; }
.cal-legende span { display: inline-flex; align-items: center; gap: 6px; }
.lg { width: 12px; height: 12px; border-radius: 50%; }

/* Graphique douleur */
.graph-wrap { width: 100%; overflow-x: auto; }
.graph-vide { color: var(--muted); font-style: italic; font-size: 14px; padding: 30px 0; text-align: center; }
svg.graph text { font-family: var(--mono); font-size: 11px; fill: var(--muted); }

/* Calendrier général (agenda) */
.vue-toggle { display: inline-flex; border: 1px solid var(--line); border-radius: 9px; overflow: hidden; }
.vue-toggle button {
  border: none; background: #fff; padding: 7px 14px; font: inherit; font-size: 13px;
  cursor: pointer; color: var(--muted); transition: background .12s ease, color .12s ease;
}
.vue-toggle button + button { border-left: 1px solid var(--line); }
.vue-toggle button:hover { color: var(--accent); }
.vue-toggle button.actif { background: var(--accent); color: #fff; }

.cal-case.sel { box-shadow: inset 0 0 0 2px var(--accent); background: var(--accent-soft); }
.agenda-grille { height: var(--cal-h); grid-template-rows: auto; grid-auto-rows: 1fr; }
.agenda-grille .cal-case {
  aspect-ratio: auto; min-height: 0; padding: 5px 6px;
  display: flex; flex-direction: column; align-items: stretch; gap: 2px; overflow: hidden;
}
.agenda-grille .cal-case .cal-jour-num { font-size: 12px; font-weight: 600; color: var(--muted); }
.agenda-grille .cal-case.ajd .cal-jour-num { color: var(--accent); }
.cal-noms { display: flex; flex-direction: column; gap: 1px; overflow: hidden; min-width: 0; }
.nom-mini {
  font-size: 10.5px; line-height: 1.35; color: var(--ink);
  display: flex; align-items: center; gap: 4px; min-width: 0; overflow: hidden;
}
.nom-mini .nm-dot { width: 6px; height: 6px; border-radius: 50%; flex: none; }
.nm-dot { width: 6px; height: 6px; border-radius: 50%; flex: none; }
.nom-txt { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.nom-plus { font-size: 10px; color: var(--muted); font-family: var(--mono); }
@media (max-width: 760px) {
  .agenda-grille { height: auto; grid-auto-rows: minmax(58px, auto); }
  .agenda-grille .cal-case { min-height: 58px; }
  .nom-mini { font-size: 9.5px; }
}

.agenda-jour h2 { font-size: 15px; }
.jour-liste { max-height: 56vh; overflow-y: auto; overflow-x: hidden; scrollbar-gutter: stable; margin: 4px 0 4px; }
.jour-liste .agenda-item:first-child { margin-top: 0; }

/* Vue semaine */
.semaine-grille { gap: 8px; align-items: stretch; height: var(--cal-h); grid-auto-rows: 1fr; }
.sem-col {
  border: 1px solid var(--line); border-radius: 12px; background: #fff;
  overflow: hidden; display: flex; flex-direction: column; min-width: 0;
  height: 100%;
}
.sem-col.ajd { border-color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); }
.sem-tete {
  flex: none;
  border: none; background: var(--accent-soft); color: var(--ink);
  padding: 8px 6px; cursor: pointer; border-bottom: 1px solid var(--line);
  display: flex; flex-direction: column; align-items: center; gap: 1px;
  transition: background .12s ease;
}
.sem-tete:hover { background: #E6E3FB; }
.sem-col.ajd .sem-tete { background: var(--accent); color: #fff; }
.sem-jour { font-family: var(--mono); font-size: 10px; letter-spacing: 0.06em; text-transform: uppercase; opacity: .85; }
.sem-num { font-size: 16px; font-weight: 600; line-height: 1.1; }
.sem-liste {
  flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 2px; padding: 6px;
  min-width: 0; overflow-y: auto; overflow-x: hidden; scrollbar-gutter: stable;
}
.sem-item {
  display: flex; align-items: center; gap: 5px; padding: 4px 5px; border-radius: 7px;
  text-decoration: none; color: var(--ink); font-size: 12px; min-width: 0; flex: none;
}
.sem-item:hover { background: var(--accent-soft); }
.sem-item .nom-txt { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.sem-vide { color: var(--muted); text-align: center; padding: 10px 0; font-size: 13px; }
@media (max-width: 760px) {
  .semaine-grille { grid-template-columns: 1fr; height: auto; grid-auto-rows: auto; }
  .sem-col { height: auto; }
  .sem-liste { max-height: 280px; }
  .sem-tete { flex-direction: row; gap: 8px; justify-content: flex-start; padding-left: 12px; }
}
.sem-h { font-family: var(--mono); font-size: 10px; color: var(--muted); flex: none; }

/* Vue jour (créneaux) */
.jour-vue {
  height: var(--cal-h); overflow-y: auto; overflow-x: hidden; scrollbar-gutter: stable;
  border: 1px solid var(--line); border-radius: 12px; background: #fff; padding: 2px 4px;
}
.jour-sans { border-bottom: 2px solid var(--line); margin-bottom: 2px; }
.jour-sans-tete {
  font-family: var(--mono); font-size: 11px; text-transform: uppercase; letter-spacing: .06em;
  color: var(--muted); padding: 8px 6px 2px;
}
.creneau { display: flex; gap: 10px; align-items: flex-start; padding: 3px 6px; border-bottom: 1px solid var(--line); }
.creneau:last-child { border-bottom: none; }
.creneau-h { font-family: var(--mono); font-size: 12px; color: var(--muted); width: 46px; flex: none; padding-top: 8px; }
.creneau-corps { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; flex: 1; min-width: 0; padding: 4px 0; }
.creneau-pat {
  display: inline-flex; align-items: center; gap: 5px; padding: 4px 9px;
  border: 1px solid var(--line); border-radius: 999px; text-decoration: none;
  color: var(--ink); font-size: 12.5px; background: #fff; max-width: 100%;
}
.creneau-pat:hover { border-color: var(--accent); background: var(--accent-soft); }
.creneau-pat .nom-txt { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chip-eva {
  color: #fff; font-size: 10px; font-weight: 600; min-width: 16px; height: 16px;
  border-radius: 8px; display: inline-grid; place-items: center; padding: 0 3px;
}
.chip-prat {
  color: #fff; font-size: 10px; font-weight: 600; height: 16px; flex: none;
  border-radius: 8px; display: inline-grid; place-items: center; padding: 0 7px;
  white-space: nowrap; letter-spacing: 0.02em;
}
.creneau-add {
  width: 24px; height: 24px; border-radius: 7px; border: 1px dashed var(--line);
  background: #fff; color: var(--muted); cursor: pointer; font-size: 15px; line-height: 1;
  display: grid; place-items: center; flex: none;
}
.creneau-add:hover { border-color: var(--accent); color: var(--accent); border-style: solid; }
.agenda-item {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  padding: 12px 14px; border: 1px solid var(--line); border-radius: 12px;
  text-decoration: none; color: var(--ink);
  transition: border-color .12s ease, background .12s ease;
}
.agenda-item + .agenda-item { margin-top: 8px; }
.agenda-item:hover { border-color: var(--accent); background: var(--accent-soft); }
.agenda-item .who { font-weight: 600; }
.agenda-item .extrait { color: var(--muted); font-size: 13px; margin-top: 3px; }

/* Bilan oral (enregistreur) */
.aide { color: var(--muted); font-size: 13.5px; margin: 0 0 16px; }
.aide code { font-family: var(--mono); font-size: 12.5px; background: var(--accent-soft); padding: 2px 6px; border-radius: 5px; color: var(--accent-deep); }
.rec-row { display: flex; align-items: center; gap: 18px; }
.rec-btn {
  flex: none; width: 56px; height: 56px; border-radius: 50%;
  border: none; background: var(--accent); color: #fff; cursor: pointer;
  display: grid; place-items: center; position: relative;
  transition: background .15s ease, transform .08s ease;
}
.rec-btn:hover { background: var(--accent-deep); }
.rec-btn:active { transform: scale(0.96); }
.rec-btn:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
.rec-btn .dot { width: 18px; height: 18px; border-radius: 5px; background: #fff; transition: all .18s ease; }
.rec-btn.live { background: var(--live); }
.rec-btn.live .dot { width: 16px; height: 16px; border-radius: 3px; }
.rec-btn.live::after {
  content: ""; position: absolute; inset: -6px; border-radius: 50%;
  border: 2px solid var(--live); animation: pulse 1.4s ease-out infinite;
}
@keyframes pulse { 0% { transform: scale(0.9); opacity: .8; } 100% { transform: scale(1.35); opacity: 0; } }
.meter { display: flex; align-items: flex-end; gap: 4px; height: 40px; flex: 1; }
.meter .bar { flex: 1; background: var(--line); border-radius: 3px; height: 6px; transition: height .06s linear, background .12s ease; }
.meter.live .bar { background: var(--accent); }
.timer { font-family: var(--mono); font-size: 15px; color: var(--muted); min-width: 52px; text-align: right; font-variant-numeric: tabular-nums; }
.timer.live { color: var(--live); }
.hint { margin: 14px 2px 0; font-size: 13px; color: var(--muted); }
.status { margin-top: 16px; font-size: 14px; min-height: 22px; display: flex; align-items: center; gap: 10px; }
.status .spin { width: 15px; height: 15px; border-radius: 50%; border: 2px solid var(--line); border-top-color: var(--accent); animation: spin .8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.status.err { color: var(--live); }
.bilan-res { margin-top: 18px; }
.bilan-res details { margin-top: 10px; }
.bilan-res summary { cursor: pointer; font-size: 13px; color: var(--muted); }
.bilan-res .brut { margin-top: 8px; padding: 12px; background: #FBFBFD; border: 1px solid var(--line); border-radius: 10px; font-size: 13.5px; color: var(--muted); white-space: pre-wrap; }
.bilan-actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 14px; flex-wrap: wrap; }
.moteur-tag { font-family: var(--mono); font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; }

/* Liste des séances */
.seance-item { border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
.seance-item + .seance-item { margin-top: 10px; }
.seance-item .tete { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.seance-item .date { font-weight: 600; font-size: 14px; }
.seance-item .fait { color: var(--muted); font-size: 14px; margin-top: 6px; white-space: pre-wrap; }

/* Barre Reformuler (IA) */
.reform-row { display: flex; align-items: center; gap: 10px; margin: -6px 0 8px; }
.reform-status { font-size: 12px; color: var(--muted); }
.reform-status.err { color: var(--live); }
.reform-status .spin { display: inline-block; width: 12px; height: 12px; vertical-align: -2px; border-radius: 50%; border: 2px solid var(--line); border-top-color: var(--accent); animation: spin .8s linear infinite; }

/* Modale séance */
.overlay {
  position: fixed; inset: 0; background: rgba(22,26,35,0.42);
  display: none; align-items: center; justify-content: center; padding: 20px; z-index: 50;
}
.overlay.ouvert { display: flex; }
.modale {
  width: 100%; max-width: 460px; background: var(--surface);
  border-radius: 16px; padding: 24px; box-shadow: 0 30px 60px -20px rgba(22,26,35,0.5);
}
.modale h3 { margin: 0 0 4px; font-size: 18px; letter-spacing: -0.01em; }
.modale .when { color: var(--muted); font-size: 13px; margin-bottom: 18px; }

/* Curseur EVA */
.eva { margin-bottom: 8px; }
.eva-haut { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 8px; }
.eva-val { font-family: var(--mono); font-size: 22px; font-weight: 600; }
.eva input[type=range] { width: 100%; accent-color: var(--accent); }
.eva-echelle { display: flex; justify-content: space-between; font-size: 11px; color: var(--muted); font-family: var(--mono); margin-top: 4px; }
.modale-actions { display: flex; justify-content: space-between; align-items: center; margin-top: 22px; }

@media (max-width: 760px) {
  .rail { position: static; width: 100%; height: auto; min-height: 0; flex-direction: row; align-items: center; flex-wrap: wrap; }
  .rail-foot { margin-top: 0; flex-direction: row; margin-left: auto; }
  body.app { flex-direction: column; }
  .stage { padding: 24px 18px 48px; }
  .bandeau { grid-template-columns: 1fr; }
  .grille2 { grid-template-columns: 1fr; }
}
@media (prefers-reduced-motion: reduce) {
  * { transition: none !important; }
}

/* Administration des praticiens */
.kbd {
  font-family: var(--mono); font-size: 13px; background: var(--accent-soft);
  border: 1px solid var(--line); border-radius: 7px; padding: 4px 9px; color: var(--ink);
}
.lien-discret { display: inline-block; margin-top: 12px; font-size: 13px; color: var(--muted); }
.lien-discret:hover { color: var(--accent); }
.prat-liste { list-style: none; margin: 10px 0 0; padding: 0; }
.prat-liste li {
  display: flex; align-items: center; gap: 10px; padding: 9px 4px;
  border-bottom: 1px solid var(--line);
}
.prat-liste li:last-child { border-bottom: none; }
.prat-pastille { width: 12px; height: 12px; border-radius: 50%; flex: none; }
.prat-nom { font-weight: 600; flex: 1; min-width: 0; }
.prat-liste form { margin: 0; }
.prat-ajout { display: flex; gap: 8px; margin-top: 6px; }
.prat-ajout input {
  flex: 1; min-width: 0; padding: 9px 11px; border: 1px solid var(--line);
  border-radius: 9px; font: inherit; background: #fff;
}

/* Badges de rôle de compte */
.role-tag {
  font-family: var(--mono); font-size: 10px; color: var(--muted);
  border: 1px solid var(--line); border-radius: 6px; padding: 2px 7px; flex: none;
  text-transform: uppercase; letter-spacing: 0.04em;
}
.role-admin { color: #fff; background: var(--accent); border-color: var(--accent); }
__FIN_STATIC_STYLE_CSS__

info "  · static/app.js"
mkdir -p "$APP/static"
cat > "$APP/static/app.js" << '__FIN_STATIC_APP_JS__'
/* Fiche patient : calendrier mensuel, graphique douleur (SVG), modale séance.
   Aucune dépendance externe : tout est fait main pour rester hors-ligne. */
(function () {
  "use strict";

  var MOIS = ["janvier","février","mars","avril","mai","juin","juillet","août",
              "septembre","octobre","novembre","décembre"];
  var JOURS = ["Lun","Mar","Mer","Jeu","Ven","Sam","Dim"];

  var seances = {};        // "AAAA-MM-JJ" -> {fait, douleur}
  var seancesIds = {};     // "AAAA-MM-JJ" -> id (pour la suppression)
  var vue = new Date();    // mois affiché
  vue.setDate(1);

  var grille = document.getElementById("calGrille");
  var moisLabel = document.getElementById("calMois");
  var overlay = document.getElementById("overlay");

  function iso(d) {
    return d.getFullYear() + "-" +
           String(d.getMonth() + 1).padStart(2, "0") + "-" +
           String(d.getDate()).padStart(2, "0");
  }
  function couleurDouleur(n) {
    if (!n) return null;
    if (n <= 3) return getCss("--ok");
    if (n <= 6) return getCss("--warn");
    return getCss("--danger");
  }
  function getCss(v) {
    return getComputedStyle(document.documentElement).getPropertyValue(v).trim();
  }

  /* ---------------- Calendrier ---------------- */
  function dessinerCalendrier() {
    moisLabel.textContent = MOIS[vue.getMonth()] + " " + vue.getFullYear();
    grille.innerHTML = "";
    JOURS.forEach(function (j) {
      var c = document.createElement("div");
      c.className = "cal-jour-nom";
      c.textContent = j;
      grille.appendChild(c);
    });
    var premier = new Date(vue.getFullYear(), vue.getMonth(), 1);
    var decalage = (premier.getDay() + 6) % 7; // lundi = 0
    var nbJours = new Date(vue.getFullYear(), vue.getMonth() + 1, 0).getDate();
    var ajdIso = iso(new Date());

    for (var i = 0; i < decalage; i++) {
      var v = document.createElement("div");
      v.className = "cal-case vide-case";
      grille.appendChild(v);
    }
    for (var jour = 1; jour <= nbJours; jour++) {
      var d = new Date(vue.getFullYear(), vue.getMonth(), jour);
      var key = iso(d);
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "cal-case" + (key === ajdIso ? " ajd" : "");
      btn.textContent = jour;
      var s = seances[key];
      if (s) {
        if (s.fait) {
          var fd = document.createElement("span");
          fd.className = "fait-dot";
          btn.appendChild(fd);
        }
        if (s.douleur) {
          var pt = document.createElement("span");
          pt.className = "pt";
          pt.style.background = couleurDouleur(s.douleur);
          pt.textContent = s.douleur;
          btn.appendChild(pt);
        }
      }
      (function (k) {
        btn.addEventListener("click", function () { ouvrirModale(k); });
      })(key);
      grille.appendChild(btn);
    }
  }

  /* ---------------- Graphique douleur (SVG) ---------------- */
  function dessinerGraphique() {
    var wrap = document.getElementById("graphWrap");
    var vide = document.getElementById("graphVide");
    var points = Object.keys(seances)
      .filter(function (k) { return seances[k].douleur; })
      .sort()
      .map(function (k) { return { date: k, d: seances[k].douleur }; });

    var ancien = wrap.querySelector("svg.graph");
    if (ancien) ancien.remove();

    if (points.length === 0) { vide.style.display = "block"; return; }
    vide.style.display = "none";

    var W = Math.max(560, points.length * 60 + 80);
    var H = 240, padL = 38, padR = 20, padT = 18, padB = 46;
    var plotW = W - padL - padR, plotH = H - padT - padB;
    var svgns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(svgns, "svg");
    svg.setAttribute("class", "graph");
    svg.setAttribute("viewBox", "0 0 " + W + " " + H);
    svg.setAttribute("width", W);
    svg.setAttribute("height", H);

    function x(i) {
      return padL + (points.length === 1 ? plotW / 2 : (i / (points.length - 1)) * plotW);
    }
    function y(v) { return padT + plotH - (v / 10) * plotH; }

    // Grille horizontale 0,2,4,6,8,10
    [0, 2, 4, 6, 8, 10].forEach(function (lvl) {
      var yy = y(lvl);
      var ligne = document.createElementNS(svgns, "line");
      ligne.setAttribute("x1", padL); ligne.setAttribute("x2", W - padR);
      ligne.setAttribute("y1", yy); ligne.setAttribute("y2", yy);
      ligne.setAttribute("stroke", getCss("--line"));
      ligne.setAttribute("stroke-width", lvl === 0 ? 1.5 : 1);
      svg.appendChild(ligne);
      var t = document.createElementNS(svgns, "text");
      t.setAttribute("x", padL - 8); t.setAttribute("y", yy + 4);
      t.setAttribute("text-anchor", "end");
      t.textContent = lvl;
      svg.appendChild(t);
    });

    // Aire + ligne
    var dPath = "", dArea = "";
    points.forEach(function (p, i) {
      dPath += (i === 0 ? "M" : "L") + x(i) + " " + y(p.d) + " ";
    });
    dArea = dPath + "L" + x(points.length - 1) + " " + y(0) + " L" + x(0) + " " + y(0) + " Z";

    var aire = document.createElementNS(svgns, "path");
    aire.setAttribute("d", dArea);
    aire.setAttribute("fill", getCss("--accent"));
    aire.setAttribute("opacity", "0.08");
    svg.appendChild(aire);

    var ligne2 = document.createElementNS(svgns, "path");
    ligne2.setAttribute("d", dPath);
    ligne2.setAttribute("fill", "none");
    ligne2.setAttribute("stroke", getCss("--accent"));
    ligne2.setAttribute("stroke-width", "2.5");
    ligne2.setAttribute("stroke-linejoin", "round");
    ligne2.setAttribute("stroke-linecap", "round");
    svg.appendChild(ligne2);

    // Points + dates
    points.forEach(function (p, i) {
      var c = document.createElementNS(svgns, "circle");
      c.setAttribute("cx", x(i)); c.setAttribute("cy", y(p.d));
      c.setAttribute("r", "5");
      c.setAttribute("fill", couleurDouleur(p.d));
      c.setAttribute("stroke", "#fff");
      c.setAttribute("stroke-width", "2");
      var titre = document.createElementNS(svgns, "title");
      titre.textContent = p.date + " — EVA " + p.d;
      c.appendChild(titre);
      svg.appendChild(c);

      if (points.length <= 14 || i % 2 === 0) {
        var t = document.createElementNS(svgns, "text");
        t.setAttribute("x", x(i)); t.setAttribute("y", H - 24);
        t.setAttribute("text-anchor", "middle");
        t.setAttribute("font-size", "10");
        t.textContent = p.date.slice(5); // MM-JJ
        svg.appendChild(t);
      }
    });

    wrap.appendChild(svg);
  }

  /* ---------------- Modale ---------------- */
  function ouvrirModale(key) {
    var s = seances[key] || { fait: "", douleur: 0, heure: "", praticien: "" };
    document.getElementById("fDate").value = key;
    document.getElementById("fHeure").value = s.heure || "";
    document.getElementById("fPraticien").value = s.praticien || "";
    document.getElementById("fFait").value = s.fait || "";
    var d = s.douleur || 0;
    document.getElementById("fDouleur").value = d;
    majEva(d);
    document.getElementById("modDate").textContent = formaterDate(key);
    var supBtn = document.getElementById("modSupprimer");
    supBtn.style.visibility = seances[key] ? "visible" : "hidden";
    supBtn.dataset.key = key;
    overlay.classList.add("ouvert");
    if (window.__resetReform) window.__resetReform();
    document.getElementById("fFait").focus();
  }
  function fermerModale() { overlay.classList.remove("ouvert"); }

  function majEva(v) {
    document.getElementById("evaVal").textContent = (v > 0) ? v : "—";
  }
  function formaterDate(key) {
    var p = key.split("-");
    return p[2] + " " + MOIS[parseInt(p[1], 10) - 1] + " " + p[0];
  }

  /* ---------------- Données ---------------- */
  function charger() {
    fetch(window.SEANCES_URL)
      .then(function (r) { return r.json(); })
      .then(function (data) {
        seances = {};
        seancesIds = {};
        data.forEach(function (s) {
          seances[s.date_seance] = { fait: s.fait || "", douleur: s.douleur || 0, heure: s.heure || "", praticien: s.praticien || "" };
          seancesIds[s.date_seance] = s.id;
        });
        dessinerCalendrier();
        dessinerGraphique();
      });
  }

  /* ---------------- Événements ---------------- */
  document.getElementById("calPrev").addEventListener("click", function () {
    vue.setMonth(vue.getMonth() - 1); dessinerCalendrier();
  });
  document.getElementById("calNext").addEventListener("click", function () {
    vue.setMonth(vue.getMonth() + 1); dessinerCalendrier();
  });
  document.getElementById("fDouleur").addEventListener("input", function (e) {
    majEva(parseInt(e.target.value, 10));
  });
  document.getElementById("modFermer").addEventListener("click", fermerModale);
  overlay.addEventListener("click", function (e) { if (e.target === overlay) fermerModale(); });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && overlay.classList.contains("ouvert")) fermerModale();
  });

  document.getElementById("modSupprimer").addEventListener("click", function () {
    if (!confirm("Supprimer cette séance ?")) return;
    var key = this.dataset.key;
    var sid = seancesIds[key];
    if (!sid) { fermerModale(); return; }
    var f = document.createElement("form");
    f.method = "post";
    f.action = window.SUPPR_BASE.replace(/\/0\/supprimer$/, "/" + sid + "/supprimer");
    document.body.appendChild(f);
    f.submit();
  });

  // Bouton « Modifier » dans la liste des séances
  Array.prototype.forEach.call(document.querySelectorAll(".js-edit"), function (b) {
    b.addEventListener("click", function () {
      ouvrirModale(b.dataset.date);
    });
  });

  // Reformulation IA du champ « ce qui a été fait »
  var reformBtn = document.getElementById("reformBtn");
  if (reformBtn) {
    var reformUndo = document.getElementById("reformUndo");
    var reformStatus = document.getElementById("reformStatus");
    var avantReform = "";
    window.__resetReform = function () {
      reformUndo.style.display = "none";
      reformStatus.textContent = "";
      reformStatus.className = "reform-status";
      avantReform = "";
    };
    reformBtn.addEventListener("click", function () {
      var f = document.getElementById("fFait");
      var t = f.value.trim();
      if (!window.AUDIO_DISPO) {
        reformStatus.className = "reform-status err";
        reformStatus.textContent = "Module IA non installé. Relancez : bash installer.sh --avec-audio";
        return;
      }
      if (!t) { reformStatus.className = "reform-status"; reformStatus.textContent = "Rien à reformuler."; return; }
      reformBtn.disabled = true;
      reformStatus.className = "reform-status";
      reformStatus.innerHTML = '<span class="spin"></span> Reformulation en local…';
      var fd = new FormData();
      fd.append("texte", t);
      fetch(window.REFORM_URL, { method: "POST", body: fd })
        .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
        .then(function (res) {
          reformBtn.disabled = false;
          if (!res.ok) throw new Error(res.d.erreur || "Erreur.");
          if (res.d.moteur === "indisponible") {
            reformStatus.className = "reform-status err";
            reformStatus.textContent = "Modèle injoignable (Ollama éteint) : texte inchangé.";
            return;
          }
          avantReform = t;
          f.value = res.d.texte || t;
          reformUndo.style.display = "";
          reformStatus.className = "reform-status";
          reformStatus.textContent = "Reformulé. Relisez avant d'enregistrer.";
        })
        .catch(function (e) {
          reformBtn.disabled = false;
          reformStatus.className = "reform-status err";
          reformStatus.textContent = "Échec : " + e.message;
        });
    });
    reformUndo.addEventListener("click", function () {
      if (!avantReform) return;
      document.getElementById("fFait").value = avantReform;
      reformUndo.style.display = "none";
      reformStatus.className = "reform-status";
      reformStatus.textContent = "Texte d'origine rétabli.";
    });
  }

  charger();
})();

/* ===================== Bilan oral ===================== */
(function () {
  "use strict";
  var recBtn = document.getElementById("recBtn");
  if (!recBtn) return; // module audio non installé

  var meter = document.getElementById("meter");
  var bars = Array.prototype.slice.call(meter.querySelectorAll(".bar"));
  var timerEl = document.getElementById("timer");
  var recHint = document.getElementById("recHint");
  var statusEl = document.getElementById("bilanStatus");
  var resEl = document.getElementById("bilanRes");
  var resumeEl = document.getElementById("bilanResume");
  var brutEl = document.getElementById("bilanBrut");
  var moteurTag = document.getElementById("moteurTag");
  var btnSeance = document.getElementById("bilanSeance");
  var btnNote = document.getElementById("bilanNote");
  var dateEl = document.getElementById("bilanDate");
  var dateInfo = document.getElementById("dateInfo");

  var mediaRecorder = null, chunks = [], stream = null;
  var audioCtx = null, analyser = null, rafId = null;
  var startTime = 0, timerInt = null, douleurDetectee = 0;

  function fmt(sec) {
    var m = Math.floor(sec / 60), s = Math.floor(sec % 60);
    return m + ":" + String(s).padStart(2, "0");
  }
  function setStatus(html, err) {
    statusEl.className = "status" + (err ? " err" : "");
    statusEl.innerHTML = html;
  }
  function startMeter() {
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    var src = audioCtx.createMediaStreamSource(stream);
    analyser = audioCtx.createAnalyser();
    analyser.fftSize = 64;
    src.connect(analyser);
    var data = new Uint8Array(analyser.frequencyBinCount);
    meter.classList.add("live");
    (function loop() {
      analyser.getByteFrequencyData(data);
      bars.forEach(function (bar, i) {
        var v = data[i * 2] || 0;
        bar.style.height = (6 + (v / 255) * 34).toFixed(0) + "px";
      });
      rafId = requestAnimationFrame(loop);
    })();
  }
  function stopMeter() {
    if (rafId) cancelAnimationFrame(rafId);
    if (audioCtx) audioCtx.close();
    meter.classList.remove("live");
    bars.forEach(function (b) { b.style.height = "6px"; });
  }

  function start() {
    navigator.mediaDevices.getUserMedia({ audio: true }).then(function (s) {
      stream = s;
      chunks = [];
      mediaRecorder = new MediaRecorder(stream);
      mediaRecorder.ondataavailable = function (e) { if (e.data.size) chunks.push(e.data); };
      mediaRecorder.onstop = function () {
        var blob = new Blob(chunks, { type: mediaRecorder.mimeType || "audio/webm" });
        envoyer(blob);
      };
      mediaRecorder.start();
      recBtn.classList.add("live");
      timerEl.classList.add("live");
      recHint.textContent = "Dictée en cours… Re-cliquez pour arrêter.";
      startTime = Date.now();
      timerEl.textContent = "0:00";
      timerInt = setInterval(function () {
        timerEl.textContent = fmt((Date.now() - startTime) / 1000);
      }, 250);
      startMeter();
    }).catch(function () {
      setStatus("Accès au micro refusé. Autorisez le micro pour cette page.", true);
    });
  }
  function stop() {
    if (mediaRecorder && mediaRecorder.state !== "inactive") mediaRecorder.stop();
    if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
    clearInterval(timerInt);
    stopMeter();
    recBtn.classList.remove("live");
    timerEl.classList.remove("live");
    recHint.textContent = "Cliquez pour dicter. Re-cliquez pour arrêter et lancer la transcription.";
  }
  recBtn.addEventListener("click", function () {
    if (recBtn.classList.contains("live")) stop(); else start();
  });

  function envoyer(blob) {
    resEl.style.display = "none";
    setStatus('<span class="spin"></span> Transcription puis résumé en local… (calcul CPU, patientez)');
    var fd = new FormData();
    fd.append("audio", blob, "bilan.webm");
    fetch(window.BILAN_URL, { method: "POST", body: fd })
      .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
      .then(function (res) {
        if (!res.ok) throw new Error(res.d.erreur || "Erreur inconnue.");
        resumeEl.value = res.d.resume || "(résumé vide)";
        brutEl.textContent = res.d.transcription || "(rien transcrit)";
        douleurDetectee = res.d.douleur || 0;
        var moteur = res.d.moteur === "ollama" ? "résumé : IA locale (Ollama)" :
                     res.d.moteur === "règles" ? "résumé : mise en forme locale (Ollama injoignable)" : "";
        var dl = douleurDetectee ? " · douleur détectée : EVA " + douleurDetectee : "";
        moteurTag.textContent = moteur + dl;
        dateEl.value = window.AUJOURDHUI;
        dateEl.max = window.AUJOURDHUI;
        verifDate();
        resEl.style.display = "block";
        setStatus("Terminé. Choisissez la date puis insérez.");
      })
      .catch(function (e) { setStatus("Échec : " + e.message, true); });
  }

  function soumettre(action, champs) {
    var f = document.createElement("form");
    f.method = "post";
    f.action = action;
    Object.keys(champs).forEach(function (k) {
      var i = document.createElement("input");
      i.type = "hidden"; i.name = k; i.value = champs[k];
      f.appendChild(i);
    });
    document.body.appendChild(f);
    f.submit();
  }

  function verifDate() {
    dateInfo.textContent = "";
    var d = dateEl.value;
    if (!d) return;
    fetch(window.SEANCES_URL)
      .then(function (r) { return r.json(); })
      .then(function (data) {
        var existe = data.filter(function (s) { return s.date_seance === d; })[0];
        if (existe) {
          dateInfo.textContent = "Une séance existe déjà ce jour-là : son contenu sera remplacé.";
        } else if (d !== window.AUJOURDHUI) {
          dateInfo.textContent = "Séance antérieure : le résumé sera enregistré à cette date.";
        }
      })
      .catch(function () {});
  }
  dateEl.addEventListener("change", verifDate);

  btnSeance.addEventListener("click", function () {
    if (!resumeEl.value.trim()) return;
    soumettre(window.SEANCE_URL, {
      date_seance: dateEl.value || window.AUJOURDHUI,
      fait: resumeEl.value.trim(),
      douleur: douleurDetectee || 0,
    });
  });

  btnNote.addEventListener("click", function () {
    if (!resumeEl.value.trim()) return;
    var noteEl = document.querySelector('textarea[name="note_libre"]');
    var ancienne = noteEl ? noteEl.value.trim() : "";
    var ajout = "[" + (dateEl.value || window.AUJOURDHUI) + "] " + resumeEl.value.trim();
    soumettre(window.NOTE_URL, {
      note_libre: ancienne ? (ancienne + "\n" + ajout) : ajout,
    });
  });
})();
__FIN_STATIC_APP_JS__

info "  · static/agenda.js"
mkdir -p "$APP/static"
cat > "$APP/static/agenda.js" << '__FIN_STATIC_AGENDA_JS__'
/* Calendrier général : vues Jour, Semaine et Mois.
   - Jour : grille de créneaux de 30 min ; on assigne un patient à un créneau.
   - Semaine : 7 colonnes listant tous les patients de chaque jour.
   - Mois : grille classique (jusqu'à 3 noms + N…).
   Clic sur un patient -> sa fiche. */
(function () {
  "use strict";

  var MOIS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet",
              "août", "septembre", "octobre", "novembre", "décembre"];
  var JOURS = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"];
  var JOURS_LONG = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"];
  var H_DEBUT = 7, H_FIN = 20;   // créneaux de 7:00 à 19:30

  var agenda = {};            // "AAAA-MM-JJ" -> [ {patient_id, prenom, nom, douleur, heure, archive} ]
  var patients = [];          // [{id, prenom, nom}]
  var mode = "mois";          // "jour" | "semaine" | "mois"
  var ancre = new Date();
  var selection = null;

  var grille = document.getElementById("calGrille");
  var moisLabel = document.getElementById("calMois");
  var overlay = document.getElementById("jourOverlay");
  var jourTitre = document.getElementById("jourTitre");
  var jourSous = document.getElementById("jourSous");
  var jourListe = document.getElementById("jourListe");
  var btnJour = document.getElementById("vueJour");
  var btnSemaine = document.getElementById("vueSemaine");
  var btnMois = document.getElementById("vueMois");

  // Fenêtre d'ajout de créneau
  var crOverlay = document.getElementById("creneauOverlay");
  var crQuand = document.getElementById("creneauQuand");
  var crSelect = document.getElementById("creneauPatient");
  var crPrat = document.getElementById("creneauPraticien");
  var crDateHeure = { date: null, heure: null };

  function iso(d) {
    return d.getFullYear() + "-" +
           String(d.getMonth() + 1).padStart(2, "0") + "-" +
           String(d.getDate()).padStart(2, "0");
  }
  function getCss(v) {
    return getComputedStyle(document.documentElement).getPropertyValue(v).trim();
  }
  function couleur(n) {
    if (!n) return getCss("--muted");
    if (n <= 3) return getCss("--ok");
    if (n <= 6) return getCss("--warn");
    return getCss("--danger");
  }
  function couleurPrat(nom) {
    return (window.PRAT_COULEURS || {})[nom] || "#8A93A6";
  }
  function jolie(key) {
    var p = key.split("-");
    return p[2] + " " + MOIS[parseInt(p[1], 10) - 1] + " " + p[0];
  }
  function urlPatient(id) { return window.PATIENT_BASE.replace(/\/0$/, "/" + id); }
  function lundi(d) {
    var x = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    x.setDate(x.getDate() - ((x.getDay() + 6) % 7));
    return x;
  }
  function ligneNom(it) {
    var dot = document.createElement("span");
    dot.className = "nm-dot";
    dot.style.background = couleurPrat(it.praticien);
    var txt = document.createElement("span");
    txt.className = "nom-txt";
    txt.textContent = it.nom + " " + it.prenom;
    return [dot, txt];
  }

  /* ---------------- Vue jour ---------------- */
  function dessinerJour() {
    grille.className = "jour-vue";
    grille.innerHTML = "";
    var key = iso(ancre);
    var items = agenda[key] || [];
    var parHeure = {};
    var sansHeure = [];
    items.forEach(function (it) {
      if (it.heure) (parHeure[it.heure] = parHeure[it.heure] || []).push(it);
      else sansHeure.push(it);
    });

    if (sansHeure.length) {
      var bloc = document.createElement("div");
      bloc.className = "jour-sans";
      var t = document.createElement("div");
      t.className = "jour-sans-tete";
      t.textContent = "Sans horaire";
      bloc.appendChild(t);
      var corps = document.createElement("div");
      corps.className = "creneau-corps";
      sansHeure.forEach(function (it) { corps.appendChild(chipPatient(it)); });
      bloc.appendChild(corps);
      grille.appendChild(bloc);
    }

    for (var min = H_DEBUT * 60; min < H_FIN * 60; min += 30) {
      var hh = String(Math.floor(min / 60)).padStart(2, "0");
      var mm = String(min % 60).padStart(2, "0");
      var slot = hh + ":" + mm;
      var rang = document.createElement("div");
      rang.className = "creneau";
      var lab = document.createElement("div");
      lab.className = "creneau-h";
      lab.textContent = slot;
      rang.appendChild(lab);
      var corps2 = document.createElement("div");
      corps2.className = "creneau-corps";
      (parHeure[slot] || []).forEach(function (it) { corps2.appendChild(chipPatient(it)); });
      var add = document.createElement("button");
      add.type = "button";
      add.className = "creneau-add";
      add.textContent = "+";
      add.title = "Ajouter un patient à " + slot;
      (function (s) {
        add.addEventListener("click", function () { ouvrirCreneau(key, s); });
      })(slot);
      corps2.appendChild(add);
      rang.appendChild(corps2);
      grille.appendChild(rang);
    }
  }

  function chipPatient(it) {
    var a = document.createElement("a");
    a.className = "creneau-pat";
    a.href = urlPatient(it.patient_id);
    ligneNom(it).forEach(function (e) { a.appendChild(e); });
    if (it.praticien) {
      var b = document.createElement("span");
      b.className = "chip-prat";
      b.textContent = it.praticien;
      b.style.background = couleurPrat(it.praticien);
      a.appendChild(b);
    }
    return a;
  }

  /* ---------------- Vue mois ---------------- */
  function dessinerMois() {
    grille.className = "cal-grille agenda-grille";
    grille.innerHTML = "";
    JOURS.forEach(function (j) {
      var c = document.createElement("div");
      c.className = "cal-jour-nom";
      c.textContent = j;
      grille.appendChild(c);
    });
    var an = ancre.getFullYear(), mo = ancre.getMonth();
    var premier = new Date(an, mo, 1);
    var decalage = (premier.getDay() + 6) % 7;
    var nbJours = new Date(an, mo + 1, 0).getDate();
    var ajd = iso(new Date());
    for (var i = 0; i < decalage; i++) {
      var v = document.createElement("div");
      v.className = "cal-case vide-case";
      grille.appendChild(v);
    }
    for (var jour = 1; jour <= nbJours; jour++) {
      var key = iso(new Date(an, mo, jour));
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "cal-case" + (key === ajd ? " ajd" : "") +
                      (key === selection ? " sel" : "");
      var numero = document.createElement("span");
      numero.className = "cal-jour-num";
      numero.textContent = jour;
      btn.appendChild(numero);
      var items = agenda[key];
      if (items && items.length) {
        var noms = document.createElement("div");
        noms.className = "cal-noms";
        var MAX = 3;
        items.slice(0, MAX).forEach(function (it) {
          var l = document.createElement("span");
          l.className = "nom-mini";
          ligneNom(it).forEach(function (e) { l.appendChild(e); });
          noms.appendChild(l);
        });
        if (items.length > MAX) {
          var plus = document.createElement("span");
          plus.className = "nom-plus";
          plus.textContent = "+" + (items.length - MAX) + "…";
          noms.appendChild(plus);
        }
        btn.appendChild(noms);
      }
      (function (k) {
        btn.addEventListener("click", function () { ouvrirJour(k); });
      })(key);
      grille.appendChild(btn);
    }
  }

  /* ---------------- Vue semaine ---------------- */
  function dessinerSemaine() {
    grille.className = "cal-grille semaine-grille";
    grille.innerHTML = "";
    var debut = lundi(ancre);
    var ajd = iso(new Date());
    for (var i = 0; i < 7; i++) {
      var d = new Date(debut);
      d.setDate(debut.getDate() + i);
      var key = iso(d);
      var col = document.createElement("div");
      col.className = "sem-col" + (key === ajd ? " ajd" : "");
      var tete = document.createElement("button");
      tete.type = "button";
      tete.className = "sem-tete";
      var jn = document.createElement("span"); jn.className = "sem-jour"; jn.textContent = JOURS[i];
      var nm = document.createElement("span"); nm.className = "sem-num"; nm.textContent = d.getDate();
      tete.appendChild(jn); tete.appendChild(nm);
      (function (k) { tete.addEventListener("click", function () { ouvrirJour(k); }); })(key);
      col.appendChild(tete);
      var liste = document.createElement("div");
      liste.className = "sem-liste";
      var items = agenda[key] || [];
      if (!items.length) {
        var vide = document.createElement("div");
        vide.className = "sem-vide"; vide.textContent = "—";
        liste.appendChild(vide);
      } else {
        items.forEach(function (it) {
          var a = document.createElement("a");
          a.className = "sem-item";
          a.href = urlPatient(it.patient_id);
          if (it.heure) {
            var h = document.createElement("span");
            h.className = "sem-h"; h.textContent = it.heure;
            a.appendChild(h);
          }
          ligneNom(it).forEach(function (e) { a.appendChild(e); });
          liste.appendChild(a);
        });
      }
      col.appendChild(liste);
      grille.appendChild(col);
    }
  }

  function majLabel() {
    if (mode === "mois") {
      moisLabel.textContent = MOIS[ancre.getMonth()] + " " + ancre.getFullYear();
    } else if (mode === "semaine") {
      var d = lundi(ancre), f = new Date(d); f.setDate(d.getDate() + 6);
      if (d.getMonth() === f.getMonth()) {
        moisLabel.textContent = d.getDate() + " – " + f.getDate() + " " + MOIS[d.getMonth()] + " " + d.getFullYear();
      } else {
        moisLabel.textContent = d.getDate() + " " + MOIS[d.getMonth()] + " – " + f.getDate() + " " + MOIS[f.getMonth()] + " " + f.getFullYear();
      }
    } else {
      var jl = JOURS_LONG[(ancre.getDay() + 6) % 7];
      moisLabel.textContent = jl.charAt(0).toUpperCase() + jl.slice(1) + " " +
                              ancre.getDate() + " " + MOIS[ancre.getMonth()] + " " + ancre.getFullYear();
    }
  }

  function dessiner() {
    if (mode === "mois") dessinerMois();
    else if (mode === "semaine") dessinerSemaine();
    else dessinerJour();
    majLabel();
    btnJour.classList.toggle("actif", mode === "jour");
    btnSemaine.classList.toggle("actif", mode === "semaine");
    btnMois.classList.toggle("actif", mode === "mois");
  }

  /* ---------------- Fenêtre du jour (liste) ---------------- */
  function ouvrirJour(key) {
    selection = key;
    if (mode === "mois") dessiner();
    var items = agenda[key] || [];
    jourTitre.textContent = "Séances du " + jolie(key);
    jourSous.textContent = items.length ? (items.length + " patient" + (items.length > 1 ? "s" : "")) : "";
    jourListe.innerHTML = "";
    if (!items.length) {
      var vide = document.createElement("div");
      vide.className = "vide"; vide.style.padding = "26px";
      vide.textContent = "Aucune séance ce jour-là.";
      jourListe.appendChild(vide);
    } else {
      items.forEach(function (it) {
        var a = document.createElement("a");
        a.className = "agenda-item";
        a.href = urlPatient(it.patient_id);
        var gauche = document.createElement("div"); gauche.style.minWidth = "0";
        var who = document.createElement("div"); who.className = "who";
        who.textContent = (it.heure ? it.heure + " · " : "") + it.nom + " " + it.prenom + (it.archive ? "  · archivé" : "");
        gauche.appendChild(who);
        if (it.fait) {
          var ex = document.createElement("div"); ex.className = "extrait";
          var t = it.fait.replace(/\s+/g, " ").trim();
          ex.textContent = t.length > 90 ? t.slice(0, 90) + "…" : t;
          gauche.appendChild(ex);
        }
        a.appendChild(gauche);
        if (it.praticien) {
          var past = document.createElement("span"); past.className = "pastille";
          var pip = document.createElement("span"); pip.className = "pip"; pip.style.background = couleurPrat(it.praticien);
          past.appendChild(pip); past.appendChild(document.createTextNode(it.praticien));
          a.appendChild(past);
        }
        jourListe.appendChild(a);
      });
    }
    overlay.classList.add("ouvert");
  }
  function fermerJour() { overlay.classList.remove("ouvert"); }

  /* ---------------- Ajout de créneau ---------------- */
  function ouvrirCreneau(date, heure) {
    crDateHeure = { date: date, heure: heure };
    crQuand.textContent = jolie(date) + " à " + heure;
    crSelect.innerHTML = "";
    if (!patients.length) {
      var o = document.createElement("option");
      o.textContent = "Aucun patient actif"; o.disabled = true;
      crSelect.appendChild(o);
    } else {
      patients.forEach(function (p) {
        var o = document.createElement("option");
        o.value = p.id; o.textContent = p.nom + " " + p.prenom;
        crSelect.appendChild(o);
      });
    }
    crOverlay.classList.add("ouvert");
  }
  function fermerCreneau() { crOverlay.classList.remove("ouvert"); }

  function ajouterCreneau() {
    var pid = crSelect.value;
    if (!pid) { fermerCreneau(); return; }
    var fd = new FormData();
    fd.append("date", crDateHeure.date);
    fd.append("heure", crDateHeure.heure);
    fd.append("praticien", crPrat ? crPrat.value : "");
    fetch(window.CRENEAU_BASE.replace(/\/0\/creneau$/, "/" + pid + "/creneau"),
          { method: "POST", body: fd })
      .then(function () { return charger(); })
      .then(function () { fermerCreneau(); dessiner(); })
      .catch(function () { fermerCreneau(); });
  }

  /* ---------------- Données ---------------- */
  function charger() {
    return fetch(window.AGENDA_URL)
      .then(function (r) { return r.json(); })
      .then(function (data) {
        agenda = {};
        data.forEach(function (s) {
          (agenda[s.date_seance] = agenda[s.date_seance] || []).push(s);
        });
      });
  }

  /* ---------------- Navigation & événements ---------------- */
  document.getElementById("calPrev").addEventListener("click", function () {
    if (mode === "mois") ancre.setMonth(ancre.getMonth() - 1);
    else if (mode === "semaine") ancre.setDate(ancre.getDate() - 7);
    else ancre.setDate(ancre.getDate() - 1);
    dessiner();
  });
  document.getElementById("calNext").addEventListener("click", function () {
    if (mode === "mois") ancre.setMonth(ancre.getMonth() + 1);
    else if (mode === "semaine") ancre.setDate(ancre.getDate() + 7);
    else ancre.setDate(ancre.getDate() + 1);
    dessiner();
  });
  btnJour.addEventListener("click", function () { mode = "jour"; dessiner(); });
  btnSemaine.addEventListener("click", function () { mode = "semaine"; dessiner(); });
  btnMois.addEventListener("click", function () { mode = "mois"; dessiner(); });

  document.getElementById("jourFermer").addEventListener("click", fermerJour);
  overlay.addEventListener("click", function (e) { if (e.target === overlay) fermerJour(); });
  document.getElementById("creneauAnnuler").addEventListener("click", fermerCreneau);
  document.getElementById("creneauOk").addEventListener("click", ajouterCreneau);
  crOverlay.addEventListener("click", function (e) { if (e.target === crOverlay) fermerCreneau(); });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    if (overlay.classList.contains("ouvert")) fermerJour();
    if (crOverlay.classList.contains("ouvert")) fermerCreneau();
  });

  function construireLegende() {
    var el = document.getElementById("calLegende");
    if (!el) return;
    el.innerHTML = "";
    (window.PRATICIENS || []).forEach(function (nom) {
      var s = document.createElement("span");
      var dot = document.createElement("span");
      dot.className = "lg";
      dot.style.background = couleurPrat(nom);
      s.appendChild(dot);
      s.appendChild(document.createTextNode(" " + nom));
      el.appendChild(s);
    });
  }
  function remplirPraticiens() {
    if (!crPrat) return;
    crPrat.innerHTML = "";
    (window.PRATICIENS || []).forEach(function (nom) {
      var o = document.createElement("option");
      o.value = nom; o.textContent = nom;
      crPrat.appendChild(o);
    });
  }
  construireLegende();
  remplirPraticiens();

  Promise.all([
    charger(),
    fetch(window.PATIENTS_URL).then(function (r) { return r.json(); })
      .then(function (d) { patients = d; }).catch(function () { patients = []; })
  ]).then(function () { dessiner(); })
    .catch(function () {
      grille.innerHTML = '<div class="vide" style="padding:30px;">Impossible de charger l\'agenda.</div>';
    });
})();
__FIN_STATIC_AGENDA_JS__


# 4) Lanceur double-cliquable
cat > "$APP/demarrer.command" << '__MAC_DEMARRER__'
#!/bin/bash
cd "$HOME/cabinet-kine" || exit 1
source venv/bin/activate
if command -v ollama >/dev/null 2>&1; then
  if ! curl -s -o /dev/null --max-time 2 http://127.0.0.1:11434/api/tags 2>/dev/null; then
    (ollama serve >/dev/null 2>&1 &)
    sleep 2
  fi
fi
echo "Cabinet kine — demarrage... Laissez CETTE fenetre ouverte pendant l'utilisation."
python app.py
__MAC_DEMARRER__
chmod +x "$APP/demarrer.command"

# 5) Script de secours (reinitialiser un mot de passe)
cat > "$APP/reinitialiser.command" << '__MAC_REINIT__'
#!/bin/bash
cd "$HOME/cabinet-kine" || exit 1
source venv/bin/activate
cat > .reinit_tmp.py << 'PY'
import sqlite3, getpass, sys
from werkzeug.security import generate_password_hash
db = sqlite3.connect("cabinet.db")
rows = db.execute("SELECT identifiant, role FROM kine ORDER BY id").fetchall()
if not rows:
    print("Aucun compte dans la base."); sys.exit(0)
print("Comptes existants :")
for ident, role in rows:
    print("  - %s (%s)" % (ident, role))
cible = input("\nIdentifiant a reinitialiser : ").strip()
if not db.execute("SELECT 1 FROM kine WHERE identifiant = ?", (cible,)).fetchone():
    print("Identifiant introuvable."); sys.exit(1)
mdp = getpass.getpass("Nouveau mot de passe (6 caracteres min) : ")
if len(mdp) < 6:
    print("Mot de passe trop court."); sys.exit(1)
db.execute("UPDATE kine SET mdp_hash = ? WHERE identifiant = ?",
           (generate_password_hash(mdp), cible))
db.commit()
print("Mot de passe de '%s' reinitialise." % cible)
PY
python .reinit_tmp.py
rm -f .reinit_tmp.py
echo ""
echo "(Vous pouvez fermer cette fenetre.)"
read -r _
__MAC_REINIT__
chmod +x "$APP/reinitialiser.command"

# 6) Message final + ouverture du dossier
echo ""
echo "  ============================================================"
echo "  Installation terminee."
echo ""
echo "  Pour LANCER l'application : double-cliquez sur"
echo "        demarrer.command"
echo "  dans le dossier qui va s'ouvrir (~/cabinet-kine)."
echo ""
echo "  Puis, dans le navigateur, ouvrez l'adresse affichee"
echo "  (https://localhost:5001). Au 1er acces, acceptez"
echo "  l'avertissement de certificat (Avance > Continuer)."
echo "  Connectez-vous avec   admin / admin   puis changez"
echo "  le mot de passe (menu « Securite »)."
echo "  ============================================================"
echo ""
open "$APP" 2>/dev/null
echo "  (Appuyez sur Entree pour fermer cette fenetre.)"
read -r _
