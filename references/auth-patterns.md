# Auth Bypass Patterns

Dev-mode auth bypass patterns for smoke testing. The bypass uses a cookie
(`__dev_bypass=1`) checked BEFORE the auth provider middleware runs. Only
active in `NODE_ENV=development`.

---

## Clerk

### Middleware (`src/middleware.ts`):
```typescript
import { clerkMiddleware } from '@clerk/nextjs/server';
import { NextResponse } from 'next/server';

export default function middleware(request: NextRequest) {
  // --- DEV SMOKE TEST BYPASS ---
  if (process.env.NODE_ENV === 'development') {
    const bypass = request.cookies.get('__dev_bypass');
    if (bypass?.value === '1') {
      return NextResponse.next();
    }
  }
  // --- END BYPASS ---

  return clerkMiddleware()(request);
}
```

### Auth helper (`src/lib/supabase/server.ts` or `src/lib/auth.ts`):
```typescript
export async function getAuthUserId(): Promise<string> {
  if (process.env.NODE_ENV === 'development') {
    const cookieStore = await cookies();
    const bypass = cookieStore.get('__dev_bypass');
    if (bypass?.value === '1') {
      return 'DEV_BYPASS_USER_ID';
    }
  }

  const { userId } = await auth();
  if (!userId) throw new Error('Unauthorized');
  return userId;
}
```

### Critical: ALL API routes must use `getAuthUserId()`, never `auth()` directly.
Scan for violations:
```bash
grep -rn "auth()" src/app/api/ --include="*.ts" | grep -v "getAuthUserId\|node_modules\|// "
```

---

## NextAuth / Auth.js

### Middleware (`middleware.ts`):
```typescript
export function middleware(request: NextRequest) {
  if (process.env.NODE_ENV === 'development') {
    const bypass = request.cookies.get('__dev_bypass');
    if (bypass?.value === '1') {
      return NextResponse.next();
    }
  }
  // ... existing NextAuth middleware (withAuth, etc.)
}
```

### Session helper:
```typescript
export async function getSession() {
  if (process.env.NODE_ENV === 'development') {
    const cookieStore = await cookies();
    const bypass = cookieStore.get('__dev_bypass');
    if (bypass?.value === '1') {
      return {
        user: { id: 'DEV_BYPASS_USER_ID', email: 'dev@test.com', name: 'Dev User' },
        expires: new Date(Date.now() + 86400000).toISOString(),
      };
    }
  }
  return await getServerSession(authOptions);
}
```

---

## Supabase Auth

### Middleware (`middleware.ts`):
Same cookie check pattern before Supabase middleware.

### Server client helper:
```typescript
export async function getAuthUser() {
  if (process.env.NODE_ENV === 'development') {
    const cookieStore = await cookies();
    const bypass = cookieStore.get('__dev_bypass');
    if (bypass?.value === '1') {
      return { id: 'DEV_BYPASS_USER_ID', email: 'dev@test.com', role: 'authenticated' };
    }
  }
  const supabase = createServerClient(/* ... */);
  const { data: { user } } = await supabase.auth.getUser();
  return user;
}
```

### Important — Supabase RLS:
Middleware bypass does NOT bypass Row Level Security. DB queries from bypassed
API routes may still fail if RLS policies require a real JWT. Options:
1. Use service role key in dev for smoke test queries
2. Accept that DB-backed routes may 500 (flag as known limitation)
3. Create a real test user in Supabase and use their ID as `dev_user_id`

---

## Custom JWT

Generic pattern — find the JWT validation function and add the bypass before it:
```typescript
if (process.env.NODE_ENV === 'development') {
  const bypass = request.cookies.get('__dev_bypass');
  if (bypass?.value === '1') {
    request.user = { id: 'DEV_BYPASS_USER_ID' };
    return next();
  }
}
// ... existing JWT validation
```

---

## No Auth

Set `auth.type: "none"` in config. Step 2 is skipped entirely.
