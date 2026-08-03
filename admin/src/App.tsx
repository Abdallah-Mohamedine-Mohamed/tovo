import { Authenticated, Refine } from '@refinedev/core';
import {
  AuthPage,
  ErrorComponent,
  ThemedLayoutV2,
  useNotificationProvider,
} from '@refinedev/antd';
import routerProvider, { NavigateToResource } from '@refinedev/react-router';
import { dataProvider, liveProvider } from '@refinedev/supabase';
import { BrowserRouter, Outlet, Route, Routes } from 'react-router';
import { ConfigProvider, App as AntdApp } from 'antd';
import frFR from 'antd/locale/fr_FR';
import '@refinedev/antd/dist/reset.css';

import { authProvider } from './authProvider';
import { supabaseClient } from './supabaseClient';
import { OrderList } from './pages/orders';
import { DispatchList } from './pages/dispatch';
import { MerchantList } from './pages/merchants';
import { CashList, DriverList } from './pages/drivers';
import { SettingsEdit } from './pages/settings';

/**
 * Administration Tovo.
 *
 * Les données passent directement par Supabase, sans transiter par notre
 * backend : chaque écran est une lecture ou une écriture simple, et la RLS
 * fait déjà le contrôle d'accès. Y intercaler une API n'ajouterait qu'un
 * intermédiaire à maintenir.
 *
 * Le `liveProvider` branche Realtime : une commande qui change d'état se met
 * à jour dans le tableau sans rafraîchissement.
 */
export const App = () => (
  <BrowserRouter>
    <ConfigProvider
      locale={frFR}
      theme={{
        token: {
          colorPrimary: '#006666',
          borderRadius: 8,
        },
      }}
    >
      <AntdApp>
        <Refine
          dataProvider={dataProvider(supabaseClient)}
          liveProvider={liveProvider(supabaseClient)}
          authProvider={authProvider}
          routerProvider={routerProvider}
          notificationProvider={useNotificationProvider}
          options={{
            syncWithLocation: true,
            warnWhenUnsavedChanges: true,
            liveMode: 'auto',
            disableTelemetry: true,
          }}
          resources={[
            {
              name: 'orders',
              list: '/orders',
              meta: { label: 'Commandes' },
            },
            {
              name: 'dispatch',
              list: '/dispatch',
              meta: { label: 'Dispatch' },
            },
            {
              name: 'merchants',
              list: '/merchants',
              meta: { label: 'Boutiques' },
            },
            {
              name: 'driver_profiles',
              list: '/drivers',
              meta: { label: 'Livreurs' },
            },
            {
              name: 'driver_cash_ledger',
              list: '/cash',
              meta: { label: 'Collectes' },
            },
            {
              name: 'platform_settings',
              edit: '/settings',
              meta: { label: 'Paramètres' },
            },
          ]}
        >
          <Routes>
            <Route
              element={
                <Authenticated key="protege" fallback={<NavigateToResource />}>
                  <ThemedLayoutV2>
                    <Outlet />
                  </ThemedLayoutV2>
                </Authenticated>
              }
            >
              <Route index element={<OrderList />} />
              <Route path="/orders" element={<OrderList />} />
              <Route path="/dispatch" element={<DispatchList />} />
              <Route path="/merchants" element={<MerchantList />} />
              <Route path="/drivers" element={<DriverList />} />
              <Route path="/cash" element={<CashList />} />
              <Route path="/settings" element={<SettingsEdit />} />
              <Route path="*" element={<ErrorComponent />} />
            </Route>

            <Route
              element={
                <Authenticated key="public" fallback={<Outlet />}>
                  <NavigateToResource resource="orders" />
                </Authenticated>
              }
            >
              <Route
                path="/login"
                element={
                  <AuthPage
                    type="login"
                    title="Tovo — Administration"
                    registerLink={false}
                    forgotPasswordLink={false}
                  />
                }
              />
            </Route>
          </Routes>
        </Refine>
      </AntdApp>
    </ConfigProvider>
  </BrowserRouter>
);
