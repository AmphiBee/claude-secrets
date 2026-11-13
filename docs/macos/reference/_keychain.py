"""Remplace Secret/GLib (libsecret) par le trousseau macOS.

Tout le coffre est UN seul élément de trousseau (service « claude-secrets-vault »,
compte « vault ») contenant un JSON {nom: {value, export, source}}. Aucune valeur
ne transite par la ligne de commande : appels directs à Security.framework.
"""
import atexit, ctypes, ctypes.util, enum, fcntl, json, os, pathlib

SERVICE = os.environ.get("CLAUDE_SECRETS_SERVICE", "claude-secrets-vault").encode()  # surcharge : tests
ACCOUNT = b"vault"
OWNER = "claude-secrets"
NOT_FOUND = -25300
_sec = ctypes.CDLL(ctypes.util.find_library("Security"))
_u32, _vp = ctypes.c_uint32, ctypes.c_void_p
_sec.SecKeychainFindGenericPassword.argtypes = [_vp, _u32, ctypes.c_char_p, _u32, ctypes.c_char_p,
                                                ctypes.POINTER(_u32), ctypes.POINTER(_vp), ctypes.POINTER(_vp)]
_sec.SecKeychainAddGenericPassword.argtypes = [_vp, _u32, ctypes.c_char_p, _u32, ctypes.c_char_p,
                                               _u32, ctypes.c_char_p, ctypes.POINTER(_vp)]
_sec.SecKeychainItemModifyAttributesAndData.argtypes = [_vp, _vp, _u32, ctypes.c_char_p]
_sec.SecKeychainItemFreeContent.argtypes = [_vp, _vp]


class GError(Exception):
    def __init__(self, message=""):
        super().__init__(message)
        self.message = message


class GLib:
    Error = GError


def _find():
    n, p, item = _u32(0), _vp(), _vp()
    rc = _sec.SecKeychainFindGenericPassword(None, len(SERVICE), SERVICE, len(ACCOUNT), ACCOUNT,
                                             ctypes.byref(n), ctypes.byref(p), ctypes.byref(item))
    if rc != 0:
        return rc, None, None
    data = ctypes.string_at(p, n.value)
    _sec.SecKeychainItemFreeContent(None, p)
    return 0, data, item


_state = {"vault": None, "dirty": False, "lock": None}


def _load():
    if _state["vault"] is None:
        rc, data, _ = _find()
        if rc == NOT_FOUND:
            _state["vault"] = {}
        elif rc != 0:
            raise GError(f"trousseau inaccessible (code {rc}) : ouvrez une session graphique "
                         "(le trousseau est verrouillé en SSH)")
        else:
            _state["vault"] = json.loads(data.decode("utf-8") or "{}")
    return _state["vault"]


def _lock():
    if _state["lock"] is None:   # un seul écrivain à la fois (verrou tenu jusqu'à la fin du processus)
        d = pathlib.Path.home() / ".config/claude-secrets"
        d.mkdir(parents=True, exist_ok=True)
        f = open(d / ".vault.lock", "w")
        fcntl.flock(f, fcntl.LOCK_EX)
        _state["lock"] = f
        _state["vault"] = None   # relire après avoir obtenu le verrou


def _flush():
    if not _state["dirty"]:
        return
    data = json.dumps(_state["vault"], ensure_ascii=False, sort_keys=True).encode("utf-8")
    rc, _, item = _find()
    if rc == 0:
        rc = _sec.SecKeychainItemModifyAttributesAndData(item, None, len(data), data)
    else:
        rc = _sec.SecKeychainAddGenericPassword(None, len(SERVICE), SERVICE, len(ACCOUNT), ACCOUNT,
                                                len(data), data, None)
    if rc != 0:
        raise GError(f"écriture du trousseau impossible (code {rc})")
    _state["dirty"] = False


atexit.register(_flush)


class _Secret:
    def __init__(self, v):
        self._v = v

    def get_text(self):
        return self._v


class _Item:
    def __init__(self, name, e):
        self._n, self._e = name, e

    def get_attributes(self):
        return {"name": self._n, "app": OWNER, "export": self._e.get("export", "1"),
                "source": self._e.get("source", "local")}

    def get_secret(self):
        return _Secret(self._e.get("value", ""))

    def retrieve_secret_sync(self, c=None):
        return self.get_secret()


class Secret:
    class SchemaFlags(enum.IntFlag):
        NONE = 0

    class SchemaAttributeType(enum.Enum):
        STRING = 0

    class SearchFlags(enum.IntFlag):
        NONE = 0
        ALL = 2
        UNLOCK = 4
        LOAD_SECRETS = 8

    class ServiceFlags(enum.IntFlag):
        NONE = 0

    COLLECTION_DEFAULT = None

    class Schema:
        @staticmethod
        def new(*a, **k):
            return object()

    class Service:
        @staticmethod
        def get_sync(flags=0, c=None):
            rc, _, _ = _find()
            if rc not in (0, NOT_FOUND):
                raise GError(f"trousseau inaccessible (code {rc})")
            return None

    @staticmethod
    def password_store_sync(schema, attrs, collection, label, value, c=None):
        _lock()
        v = _load()
        v[attrs["name"]] = {"value": value, "export": attrs.get("export", "1"),
                            "source": attrs.get("source", "local")}
        _state["dirty"] = True
        return True

    @staticmethod
    def password_lookup_sync(schema, attrs, c=None):
        e = _load().get(attrs["name"])
        return None if e is None else e.get("value", "")

    @staticmethod
    def password_clear_sync(schema, attrs, c=None):
        _lock()
        v = _load()
        if attrs["name"] in v:
            del v[attrs["name"]]
            _state["dirty"] = True
            return True
        return False

    @staticmethod
    def password_search_sync(schema, attrs, flags=0, c=None):
        v = _load()
        if "name" in attrs:
            return [_Item(attrs["name"], v[attrs["name"]])] if attrs["name"] in v else []
        return [_Item(n, e) for n, e in v.items()]
