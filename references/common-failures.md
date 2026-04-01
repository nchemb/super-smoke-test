# Common Smoke Test Failures

Quick-reference for diagnosing and auto-fixing frequent failures.

---

## Server Issues

### Port already in use (`EADDRINUSE`)
```bash
lsof -ti:3000          # find PID
kill -9 $(lsof -ti:3000)  # kill it
```

### Stale `.next` cache (`Cannot find module`)
```bash
rm -rf .next && PORT=$PORT npx next dev -p $PORT &
```

### Missing dependency (`Module not found: Can't resolve 'X'`)
```bash
npm install X
# If sub-dependency resolution: rm -rf node_modules package-lock.json && npm install
```

---

## Auth Failures

### 401 on API routes with bypass cookie set
**Cause:** API route calls `auth()` directly instead of the bypass-aware wrapper.
```bash
grep -rn "auth()" src/app/api/ --include="*.ts" | grep -v getAuthUserId
```
**Fix:** Replace with the project's auth helper function.

### Redirect to /sign-in despite bypass cookie
**Cause:** Bypass check is missing or positioned AFTER auth middleware.
**Fix:** Ensure bypass runs BEFORE `clerkMiddleware()` / auth middleware.

### 500 on API routes that query database
**Cause:** Supabase RLS still requires real JWT. Bypass only works at app level.
**Fix:** Use service role client in dev, or flag as known limitation.

---

## Rendering Failures

### Blank white page
1. Check console for JS errors
2. Check network for failed data fetches
3. Verify route exists (not 404 rendering as blank)

### Infinite loading spinner / stuck skeleton
**Cause:** Data fetch hanging or auth context not resolving.
Check network for pending requests. Common: API call waiting for auth that
never resolves because bypass didn't propagate to the data layer.

### Hydration mismatch
**Cause:** Server/client rendering divergence.
Common culprits:
- `typeof window !== 'undefined'` in render
- `Date.now()` or `Math.random()` in render
- Nested `<button>` inside `<button>` or `<a>` inside `<a>`
**Fix:** Wrap client-only content in `useEffect` or `'use client'`.
Usually WARN, not FAIL unless it breaks visible UI.

### `crypto.randomUUID is not a function`
**Cause:** Requires secure context (HTTPS), dev runs on HTTP.
**Fix:**
```typescript
const id = crypto.randomUUID?.() ?? Math.random().toString(36).slice(2) + Date.now().toString(36);
```

---

## Network Failures

### 500 on API route
1. Read the API route source code
2. Check dev server terminal for the stack trace
3. Common: missing env var, DB connection issue, type error

### 404 on API route
- Must be named `route.ts` (not `route.tsx`, not `api.ts`)
- Must export named HTTP methods (`GET`, `POST`, etc.)
- Check file is in the correct directory

---

## Environment Issues

### Missing environment variable
```bash
ls -la .env*                                    # what env files exist?
grep "VARIABLE_NAME" .env .env.local 2>/dev/null  # is it defined?
```
If needed for the feature: add to `.env.local`.
If for an external service not needed in smoke tests: code should handle absence.

---

## Playwright CLI Issues

### `playwright-cli: command not found`
```bash
npm install -g @playwright/cli
playwright-cli install-browser
```

### Browser not installed
```bash
playwright-cli install-browser
# Or specific: playwright-cli install-browser --browser=chromium
```

### Snapshot returns empty/minimal content
Page may not have finished loading. Increase wait time:
```bash
playwright-cli navigate $URL
sleep 5  # increase from default 3
playwright-cli snapshot
```
