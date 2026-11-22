import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'MARGO — Одно открытие в день', description: 'Ваш персональный проводник по знаниям. Одна статья, новый взгляд, каждый день.' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="ru"><body>{children}</body></html>; }
