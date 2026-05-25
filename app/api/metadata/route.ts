import { NextRequest, NextResponse } from 'next/server';
import { adminSupabase } from '@/lib/supabase/admin';
import { createServerSupabaseClient } from '@/lib/supabase/server';

/**
 * GET /api/metadata
 * Returns metadata about available data in Supabase storage
 */
export async function GET(request: NextRequest) {
  try {
    // ── Check if logged-in user has their own data overrides ──────
    const { supabase } = createServerSupabaseClient(request);
    const { data: { user } } = await supabase.auth.getUser();

    // ── Fetch from master_data_files ──────────────────────────────
    const { data: masterRows, error: masterError } = await adminSupabase
      .from('master_data_files')
      .select('type, year, month');

    if (masterError) {
      console.error('Metadata master fetch error:', masterError);
      return NextResponse.json({
        success: false,
        error: 'Failed to fetch master data: ' + masterError.message,
        hasData: false
      });
    }

    // ── Fetch from user_data_files (if logged in) ─────────────────
    let userRows: any[] = [];
    if (user) {
      const { data, error: userError } = await adminSupabase
        .from('user_data_files')
        .select('type, year, month')
        .eq('user_id', user.id);
      
      if (userError) {
        console.error('Metadata user fetch error:', userError);
      } else {
        userRows = data || [];
      }
    }

    // ── Extract and deduplicate months ───────────────────────────
    const forecastMonths = new Set<string>();
    const realisedMonths = new Set<string>();

    const allRows = [...(masterRows || []), ...userRows];

    for (const row of allRows) {
      const monthStr = `${row.year}-${String(row.month).padStart(2, '0')}`;
      if (row.type === 'warning') {
        forecastMonths.add(monthStr);
      } else if (row.type === 'realised') {
        realisedMonths.add(monthStr);
      }
    }

    const hasWarningData = forecastMonths.size > 0;
    const hasRealisedData = realisedMonths.size > 0;
    const hasData = hasWarningData || hasRealisedData;

    if (!hasData) {
      return NextResponse.json({
        success: false,
        error: 'No data uploaded yet. Please upload IMD files first.',
        hasData: false
      });
    }

    const availableMonths = {
      forecast: Array.from(forecastMonths).sort((a, b) => b.localeCompare(a)),
      realised: Array.from(realisedMonths).sort((a, b) => b.localeCompare(a))
    };

    return NextResponse.json({
      success: true,
      hasData: true,
      metadata: {
        uploads: availableMonths
      },
      availableMonths,
      cachedVerifications: 0, // Calculated dynamically in frontend
      summary: {
        forecastMonths: availableMonths.forecast.length,
        realisedMonths: availableMonths.realised.length,
        cachedDates: 0
      }
    });

  } catch (error: any) {
    console.error('Metadata error:', error);
    return NextResponse.json(
      {
        success: false,
        error: error.message || 'Failed to get metadata',
        details: error.toString()
      },
      { status: 500 }
    );
  }
}
