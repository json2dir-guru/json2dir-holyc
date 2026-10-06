// json2dir: create the directory tree a JSON document describes, in the current directory.
// Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
// Pure HolyC: hand-written UTF-8 check and JSON parser; file operations are libc calls.

extern "c" I32 symlink(U8 *target, U8 *linkpath);
extern "c" I32 fchmod(I32 fd, U32 mode);
extern "c" I32 *__errno_location();

#define O_WRONLY   0x1
#define O_CREAT    0x40
#define O_EXCL     0x80
#define O_NOFOLLOW 0x20000
#define S_IFMT     0xF000
#define S_IFDIR    0x4000
#define EEXIST     17

#define K_STRING 1
#define K_ARRAY  2
#define K_OBJECT 3

class Node
{
  I64 kind;
  U8 *str;      // K_STRING: bytes (not NUL-terminated inside, NUL appended)
  I64 len;
  I64 count;    // K_ARRAY / K_OBJECT: number of items
  I64 cap;
  Node **names; // K_OBJECT: member names (K_STRING nodes)
  Node **items; // K_ARRAY elements / K_OBJECT member values
};

U8 *src;
I64 src_len;
I64 pos;

U0 Fail(U8 *msg, U8 *detail = NULL)
{
  write(2, "json2dir: ", 10);
  write(2, msg, StrLen(msg));
  if (detail) {
    write(2, ": ", 2);
    write(2, detail, StrLen(detail));
  }
  write(2, "\n", 1);
  Exit(1);
}

// ---- input ----

U0 ReadStdin()
{
  I64 cap = 65536, n;
  src = MAlloc(cap);
  src_len = 0;
  while (TRUE) {
    if (src_len == cap) {
      U8 *bigger = MAlloc(cap * 2);
      MemCpy(bigger, src, src_len);
      Free(src);
      src = bigger;
      cap *= 2;
    }
    n = read(0, src + src_len, cap - src_len);
    if (n < 0) Fail("cannot read standard input");
    if (n == 0) break;
    src_len += n;
  }
}

// §3: strict UTF-8 (no overlongs, no surrogates, nothing above U+10FFFF).
U0 CheckUtf8()
{
  I64 i = 0, need, cp, min, j;
  U8 c;
  while (i < src_len) {
    c = src[i];
    if (c < 0x80) { i++; continue; }
    if (c >= 0xC2 && c <= 0xDF) { need = 1; cp = c & 0x1F; min = 0x80; }
    else if (c >= 0xE0 && c <= 0xEF) { need = 2; cp = c & 0x0F; min = 0x800; }
    else if (c >= 0xF0 && c <= 0xF4) { need = 3; cp = c & 0x07; min = 0x10000; }
    else Fail("input is not valid UTF-8");
    if (i + need >= src_len) Fail("input is not valid UTF-8");
    for (j = 1; j <= need; j++) {
      if ((src[i + j] & 0xC0) != 0x80) Fail("input is not valid UTF-8");
      cp = (cp << 6) | (src[i + j] & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
      Fail("input is not valid UTF-8");
    i += need + 1;
  }
}

// ---- JSON parser ----

Node *NewNode(I64 kind)
{
  Node *n = MAlloc(sizeof(Node));
  n->kind = kind;
  n->str = NULL;
  n->len = 0;
  n->count = 0;
  n->cap = 0;
  n->names = NULL;
  n->items = NULL;
  return n;
}

U0 Push(Node *parent, Node *name, Node *value)
{
  if (parent->count == parent->cap) {
    I64 cap = parent->cap * 2 + 4;
    Node **items = MAlloc(cap * sizeof(Node *));
    Node **names = MAlloc(cap * sizeof(Node *));
    if (parent->count) {
      MemCpy(items, parent->items, parent->count * sizeof(Node *));
      MemCpy(names, parent->names, parent->count * sizeof(Node *));
    }
    parent->items = items;
    parent->names = names;
    parent->cap = cap;
  }
  parent->names[parent->count] = name;
  parent->items[parent->count] = value;
  parent->count++;
}

U0 SkipWs()
{
  while (pos < src_len && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r'))
    pos++;
}

I64 Hex4()
{
  I64 v = 0, i;
  U8 c;
  if (pos + 4 > src_len) Fail("input is not valid JSON", "bad \\u escape");
  for (i = 0; i < 4; i++) {
    c = src[pos++];
    v <<= 4;
    if (c >= '0' && c <= '9') v |= c - '0';
    else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
    else Fail("input is not valid JSON", "bad \\u escape");
  }
  return v;
}

Node *ParseString()
{
  Node *n = NewNode(K_STRING);
  // the decoded string is never longer than the source text
  U8 *out = MAlloc(src_len - pos + 1);
  I64 len = 0, cp, lo;
  U8 c;
  pos++; // opening quote
  while (TRUE) {
    if (pos >= src_len) Fail("input is not valid JSON", "unterminated string");
    c = src[pos++];
    if (c == '"') break;
    if (c < 0x20) Fail("input is not valid JSON", "control character in string");
    if (c != '\\') { out[len++] = c; continue; }
    if (pos >= src_len) Fail("input is not valid JSON", "unterminated string");
    c = src[pos++];
    switch (c) {
      case '"': out[len++] = '"'; break;
      case '\\': out[len++] = '\\'; break;
      case '/': out[len++] = '/'; break;
      case 'b': out[len++] = 8; break;
      case 'f': out[len++] = 12; break;
      case 'n': out[len++] = 10; break;
      case 'r': out[len++] = 13; break;
      case 't': out[len++] = 9; break;
      case 'u':
        cp = Hex4();
        if (cp >= 0xDC00 && cp <= 0xDFFF) Fail("string contains an unpaired surrogate");
        if (cp >= 0xD800 && cp <= 0xDBFF) {
          if (pos + 2 > src_len || src[pos] != '\\' || src[pos + 1] != 'u')
            Fail("string contains an unpaired surrogate");
          pos += 2;
          lo = Hex4();
          if (lo < 0xDC00 || lo > 0xDFFF) Fail("string contains an unpaired surrogate");
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
        }
        if (cp < 0x80) {
          out[len++] = cp;
        } else if (cp < 0x800) {
          out[len++] = 0xC0 | (cp >> 6);
          out[len++] = 0x80 | (cp & 0x3F);
        } else if (cp < 0x10000) {
          out[len++] = 0xE0 | (cp >> 12);
          out[len++] = 0x80 | ((cp >> 6) & 0x3F);
          out[len++] = 0x80 | (cp & 0x3F);
        } else {
          out[len++] = 0xF0 | (cp >> 18);
          out[len++] = 0x80 | ((cp >> 12) & 0x3F);
          out[len++] = 0x80 | ((cp >> 6) & 0x3F);
          out[len++] = 0x80 | (cp & 0x3F);
        }
        break;
      default:
        Fail("input is not valid JSON", "bad escape");
    }
  }
  out[len] = 0;
  n->str = out;
  n->len = len;
  return n;
}

Node *ParseValue(I64 depth);

Node *ParseArray(I64 depth)
{
  Node *n = NewNode(K_ARRAY);
  pos++; // [
  SkipWs();
  if (pos < src_len && src[pos] == ']') { pos++; return n; }
  while (TRUE) {
    Push(n, NULL, ParseValue(depth + 1));
    SkipWs();
    if (pos >= src_len) Fail("input is not valid JSON", "unterminated array");
    if (src[pos] == ',') { pos++; continue; }
    if (src[pos] == ']') { pos++; return n; }
    Fail("input is not valid JSON", "expected , or ]");
  }
}

Node *ParseObject(I64 depth)
{
  Node *n = NewNode(K_OBJECT), *name;
  pos++; // {
  SkipWs();
  if (pos < src_len && src[pos] == '}') { pos++; return n; }
  while (TRUE) {
    SkipWs();
    if (pos >= src_len || src[pos] != '"') Fail("input is not valid JSON", "expected a member name");
    name = ParseString();
    SkipWs();
    if (pos >= src_len || src[pos] != ':') Fail("input is not valid JSON", "expected :");
    pos++;
    Push(n, name, ParseValue(depth + 1));
    SkipWs();
    if (pos >= src_len) Fail("input is not valid JSON", "unterminated object");
    if (src[pos] == ',') { pos++; continue; }
    if (src[pos] == '}') { pos++; return n; }
    Fail("input is not valid JSON", "expected , or }");
  }
}

Bool Literal(U8 *word)
{
  I64 l = StrLen(word);
  return pos + l <= src_len && memcmp(src + pos, word, l) == 0;
}

Node *ParseValue(I64 depth)
{
  U8 c;
  if (depth > 10000) Fail("input is nested too deeply");
  SkipWs();
  if (pos >= src_len) Fail("input is not valid JSON", "unexpected end of input");
  c = src[pos];
  if (c == '{') return ParseObject(depth);
  if (c == '[') return ParseArray(depth);
  if (c == '"') return ParseString();
  if (Literal("true") || Literal("false")) Fail("booleans are not allowed");
  if (Literal("null")) Fail("null values are not allowed");
  if (c == '-' || (c >= '0' && c <= '9')) Fail("numbers are not allowed");
  Fail("input is not valid JSON", "unexpected character");
  return NULL;
}

// ---- validation (§4, §6), done before touching the file system ----

Bool StrIs(Node *s, U8 *word)
{
  I64 l = StrLen(word);
  return s->len == l && memcmp(s->str, word, l) == 0;
}

Bool HasNul(Node *s)
{
  I64 i;
  for (i = 0; i < s->len; i++)
    if (s->str[i] == 0) return TRUE;
  return FALSE;
}

U0 Validate(Node *v)
{
  I64 i, j;
  Node *name;
  if (v->kind == K_STRING) return;
  if (v->kind == K_ARRAY) {
    if (v->count != 2 || v->items[0]->kind != K_STRING || v->items[1]->kind != K_STRING)
      Fail("an array must be [\"link\", target] or [\"script\", content]");
    if (!StrIs(v->items[0], "link") && !StrIs(v->items[0], "script"))
      Fail("unknown array kind", v->items[0]->str);
    if (StrIs(v->items[0], "link") && HasNul(v->items[1]))
      Fail("a link target cannot contain NUL");
    return;
  }
  for (i = 0; i < v->count; i++) {
    name = v->names[i];
    if (name->len == 0 || StrIs(name, ".") || StrIs(name, "..") || HasNul(name))
      Fail("invalid name", name->str);
    for (j = 0; j < name->len; j++)
      if (name->str[j] == '/') Fail("invalid name", name->str);
    Validate(v->items[i]);
  }
}

// ---- writing (§5) ----

I64 CompareBytes(Node *a, Node *b)
{
  I64 n = a->len, r;
  if (b->len < n) n = b->len;
  r = memcmp(a->str, b->str, n);
  if (r) return r;
  return a->len - b->len;
}

// Stable insertion sort by the UTF-8 bytes of the names; for duplicates the last one stays last.
U0 SortMembers(Node *obj)
{
  I64 i, j;
  Node *nm, *val;
  for (i = 1; i < obj->count; i++) {
    nm = obj->names[i];
    val = obj->items[i];
    j = i - 1;
    while (j >= 0 && CompareBytes(obj->names[j], nm) > 0) {
      obj->names[j + 1] = obj->names[j];
      obj->items[j + 1] = obj->items[j];
      j--;
    }
    obj->names[j + 1] = nm;
    obj->items[j + 1] = val;
  }
}

U8 *JoinPath(U8 *dir, U8 *name)
{
  I64 dl = StrLen(dir), nl = StrLen(name);
  U8 *p = MAlloc(dl + nl + 2);
  MemCpy(p, dir, dl);
  p[dl] = '/';
  MemCpy(p + dl + 1, name, nl);
  p[dl + nl + 1] = 0;
  return p;
}

// Returns 0 if nothing exists, else the st_mode of the entry itself (never follows symlinks).
U32 ExistingMode(U8 *p)
{
  cStat st;
  if (lstat(p, &st) != 0) return 0;
  return st.st_mode;
}

// §5.2-§5.4: remove an existing non-directory; a directory in the way is an error.
U0 Clear(U8 *p)
{
  U32 mode = ExistingMode(p);
  if (!mode) return;
  if ((mode & S_IFMT) == S_IFDIR) Fail("a directory is in the way", p);
  if (unlink(p) != 0) Fail("cannot remove", p);
}

U0 WriteFile(U8 *p, Node *content, Bool executable)
{
  I64 done = 0, n;
  cStat st;
  // O_EXCL: never writes through an entry that appeared after Clear().
  I32 fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0x1B6);
  if (fd < 0) Fail("cannot create file", p);
  while (done < content->len) {
    n = write(fd, content->str + done, content->len - done);
    if (n <= 0) Fail("cannot write file", p);
    done += n;
  }
  if (executable) {
    if (fstat(fd, &st) != 0) Fail("cannot stat file", p);
    if (fchmod(fd, (st.st_mode & 0xFFF) | 0x49) != 0) Fail("cannot chmod file", p);
  }
  close(fd);
}

U0 Apply(U8 *dir, Node *tree)
{
  I64 i;
  U8 *p;
  U32 mode;
  Node *v;
  SortMembers(tree);
  for (i = 0; i < tree->count; i++) {
    // duplicate names: the last occurrence wins
    if (i + 1 < tree->count && CompareBytes(tree->names[i], tree->names[i + 1]) == 0) continue;
    p = JoinPath(dir, tree->names[i]->str);
    v = tree->items[i];
    if (v->kind == K_STRING) {
      Clear(p);
      WriteFile(p, v, FALSE);
    } else if (v->kind == K_ARRAY) {
      Clear(p);
      if (StrIs(v->items[0], "link")) {
        if (symlink(v->items[1]->str, p) != 0) Fail("cannot create symlink", p);
      } else {
        WriteFile(p, v->items[1], TRUE);
      }
    } else {
      mode = ExistingMode(p);
      if (!mode || (mode & S_IFMT) != S_IFDIR) {
        if (mode && unlink(p) != 0) Fail("cannot remove", p);
        if (mkdir(p, 0x1FF) != 0) Fail("cannot create directory", p);
      }
      Apply(p, v);
    }
  }
}

I32 Main(I32 argc, U8 **argv)
{
  Node *root;
  if (argc > 1) {
    write(2, "usage: json2dir < document.json\n", 32);
    return 2;
  }
  ReadStdin();
  CheckUtf8();
  pos = 0;
  // §3: a leading byte order mark may be ignored
  if (src_len >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF) pos = 3;
  root = ParseValue(0);
  SkipWs();
  if (pos != src_len) Fail("input is not valid JSON", "trailing data");
  if (root->kind != K_OBJECT) Fail("the root of the document must be an object");
  Validate(root);
  Apply(".", root);
  return 0;
}
